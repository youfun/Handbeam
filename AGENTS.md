# Handbeam

> 自主可控的 AI 编码助手 — Elixir/Phoenix + SQLite3

## 项目状态

Web UI 与 native host 共用 `Handbeam.Agent` runtime。仓库根即 Mix 工程 `:handbeam`；Android/iOS Mob host 在 `mobile/`（其中 `mobile/android/` 是 Gradle，`mobile/ios/` 是 iOS）。

## Pi Agent 优先技能

> 当当前 Agent 是 **pi agent** 且 Handbeam 应用正在运行时，优先使用 `elixir-dev` 技能查看项目情况。
>
> 理由：该技能通过 Tidewave 连接到正在运行的 BEAM VM，获取的都是**运行时最新信息**（已加载模块、注册进程、ETS 表、监督树、配置等），比静态文件快照更准确。
>
> ### 适用条件
> - Tidewave 扩展已安装并启用（pi 的 Elixir 项目自动检测）
> - Handbeam 应用正在运行（`mix phx.server` 或 `iex -S mix`）
> - 应用处于 MIX_ENV=dev 或 test
>
> ### 降级策略（Tidewave 不可用时）
> - 用 `read` 读取 `lib/handbeam/` 下的源文件（准确但可能不是最新编译版本）
> - 用 `bash "mix compile"` 确认当前编译状态
> - 用 `bash "mix test --exclude slow"` 跑测试确认行为
> - 不得凭过期的缓存或旧的输出下结论
>
> ### 典型场景
> - 查看当前已加载哪些模块 → `elixir_eval` 跑 `:code.all_loaded()`
> - 查看进程状态 → `elixir_process_info` / `elixir_top`
> - 查看 Ecto Repo 配置 → `elixir_eval` 跑 `Application.get_env(:handbeam, Handbeam.Repo)`
> - 查看模块依赖关系 → `elixir_deps_tree`
> - 查看类型/规范 → `elixir_types`
> - 定位源码行号 → `elixir_source`
> - 搜索 AST 模式 → `elixir_ast_search`

## 架构

```
Intent Layer (LiveView / CLI / SNS / Webhook)
  → Coordinator
  → RunSupervisor (CandidateQueue + Runner)
  → Agent Core (Turn) → Provider / Tools
  → Runtime events
      ├── PubSub Session snapshot → LiveView projection
      ├── TranscriptPersistence → ConversationTranscriptStore
      ├── Delivery → SNS/Webhook/CLI outbound
      └── EventRecorder → audit/debug JSONL
```

| 层 | 模块路径 | 职责 |
|----|----------|------|
| Agent Runtime | `lib/handbeam/agent/` | Agent loop、Provider、Middleware、Compactor、Runner、Coordinator |
| Tool Registry | `lib/handbeam/tool/` | 工具注册、查找、defs 生成 |
| Builtin Tools | `lib/handbeam/tool/builtin/` | Read / Edit / Bash / Write / FileSearch |
| Extension Tools | `lib/handbeam/tool/extension/` | ext__beam__docs / source / sql / eval / schemas / sup_tree / top / process_info |
| Memory Tools | `lib/handbeam/tool/memory/` | mem_recall / mem_learn / mem_reinforce / mem_associate |
| MCP Runtime | `lib/handbeam/mcp/` | Protocol / ServerRuntime / ToolBridge / Config / Diagnostic |
| Extension System | `lib/handbeam/extension/` | Loader / Registry / Manifest / HookRunner / ExtensionBridge / HotReloader |
| Security | `lib/handbeam/security/` | PathValidator / ShellPathGuard / Redactor |
| Memory Schema | `lib/handbeam/memory/` | Engram / Synapse (Ecto) |
| PubSub & Session | `lib/handbeam/pubsub/` | AgentEvent / Session (seq + snapshot) |
| Session Store | `lib/handbeam/session_store/` | Runtime session snapshot 持久化 |
| Event Recorder | `lib/handbeam/event_recorder.ex` | JSONL 事件记录（run_start / tool_start / tool_end / run_end / error）|
| Transcript Store | `lib/handbeam/conversation_transcript_store*` | 跨渠道 conversation transcript 的读写边界 |
| Data Persistence | `lib/handbeam/` | ConversationStore / WorkspaceStore (meta/files/messages JSONL + workspace CRUD) |
| Delivery | `lib/handbeam/delivery*` | assistant/tool/error outbound 投递边界（SNS/Webhook/CLI 等） |
| Log System | `lib/handbeam/log/` | 结构化日志事件 / Formatter / Redactor / Store |
| Web UI | `lib/handbeam_web/live/` | WorkspaceLive (三栏布局) |

## 当前消息/运行机制（排查 bug 优先看这里）

第一原则：

```text
LiveView is a projection, not the owner.
ConversationTranscript is the durable cross-channel source of truth.
Runner owns run lifecycle.
Session owns runtime event snapshot/replay, not conversation history.
```

### 入口与运行

- 所有用户/外部输入统一走 `Handbeam.Agent.Coordinator.add_message/3`。
- `Coordinator.add_message/3` 会：
  - 确保 `run_id`
  - 先通过 `Handbeam.Agent.TranscriptPersistence.append_inbound/3` 持久化 inbound transcript
  - 如果当前 conversation idle，启动 `Handbeam.Agent.Runner`（即便调用方传了 `deliver_as: :follow_up` / `:steer`，inbound 仍写 `delivery: "new_run"`）
  - 如果当前 conversation running，把消息送入 `Handbeam.Agent.CandidateQueue`。缺省 `deliver_as: :steer`（`Keyword.put_new`）；显式 `:follow_up` 不被覆盖。LiveView / native **运行中 Send、Enter、IME 默认 steer**；显式排队才是 follow_up。不要传 `require_running?`：UI 仍显示 running 但 run 已结束时，应起新 run 而不是 stale 错误。
  - 同一条用户消息的 `inbound_id` / `transcript_id` / `message_id`（以及 `%Message{}.id`）必须是同一个 id，对齐 transcript、CandidateQueue、Session、Turn `message_ids` 与 UI pending key。
  - UI pending 投影只放在 `Handbeam.Agent.PendingMessages`：Session 入队事件（仅 `message_id`）记 queued；Turn 注入（`message_ids`）删除对应 id；真正终态 `run_end` 把仍 queued 的标 undelivered；`:interrupted` / `"interrupted"` 不是终态，不标未送达。
- `Handbeam.Agent.Runner` 是 active run 的 owner，负责 status/cancel/task ref/queue ref。
- `Handbeam.Agent.RunSupervisor` 为每个 conversation 启动一棵小监督树：`CandidateQueue + Runner`。
- `Handbeam.Agent.Turn.run_loop/2` 只负责 agent loop/provider/tool，不拥有 UI 或 transcript 状态。

### Transcript 与 Projection

- `Handbeam.ConversationTranscriptStore` 是跨渠道对话历史边界。
- 当前实现 `Handbeam.ConversationTranscriptStore.ConversationStore` 包住 `Handbeam.ConversationStore` 的 `messages.jsonl`。
- `Handbeam.Agent.TranscriptPersistence` 在 runtime 事件路径写 transcript：
  - inbound user/SNS/Webhook message
  - assistant streaming text
  - tool_start / tool_end
  - run error
- `HandbeamWeb.WorkspaceLive` 只做 projection：
  - 发送 intent 到 Coordinator
  - optimistic render 当前用户输入
  - 从 `ConversationTranscriptStore.list/2` 恢复 timeline
  - 收 PubSub event 更新本地 UI
  - 只保存 editor/files state，不再把 assigns 里的 timeline 当持久化事实源写回
- 不要重新引入 `ConversationStore.upsert(... timeline ...)` 作为消息持久化路径。
- 旧模块 `Handbeam.Agent.ConversationPersistence` 已移除；不要再引用或恢复它。

### 运行时事件表

`Handbeam.Agent.Turn` 通过 `opts[:on_event]` 发 `{kind, payload}`；`Runner.put_persistence_callback/2` 先过 `Handbeam.Extension.HookPipeline`，再依次交给 `TranscriptPersistence.handle_event/3` 与 `Session.broadcast_event/3`。事件 kind 与 payload 以 `turn.ex` 中的 `emit/3` 调用为准：

| kind | 发出方 | payload 关键字段 | 说明 |
|------|--------|------------------|------|
| `run_start` | Turn | `model` | 每次 run 开始；`before_agent_start` hook 拦截时不会发，直接发 `run_end`/`agent_end`（`status: :error`） |
| `turn_start` / `turn_end` | Turn | `turn`，`turn_end` 另有 `stop_reason`、`status` | 单轮 provider 往返边界 |
| `message_delta` | Turn | `chunk` | assistant 可见文本流；`TranscriptPersistence` 缓冲后 flush |
| `thinking_delta` | Provider（Anthropic/StepFun） | 文本 | 高频事件，`TranscriptPersistence` 显式不 flush |
| `tool_start` | Turn | `tool`、`tool_use_id`、`input` | transcript entry id 为 `tool-<tool_use_id>` |
| `tool_end` | Turn | `tool`、`tool_use_id`、`duration_ms`、`details`、`file_path`、`output`，出错时 `error` | 更新同一条 tool entry；`TranscriptPersistence.tool_status/2` 还接受可选 `status: :cancelled`，但 Turn 目前不发它 |
| `tool_approval_requested` | Turn | `Handbeam.Permissions.InterruptData.build/3` 的 map：`type: :tool_approval`、`action_requests`（`tool_call_id`/`tool_name`/`arguments`/`suggested_pattern`）、`review_configs`、`hitl_tool_call_ids`、`auto_approved_tool_call_ids`、`workspace_path` | `ToolGuard` 中间件在 `after_tool_request` 遇到 `:prompt` 决策时把 `State.status` 置为 `:interrupted`，Turn 随即发此事件，**然后 run loop 返回**，不执行工具 |
| `candidate_message_injected` | Turn 或 Session | Turn：`deliver_as`、`count`、`message_ids`（被注入的 `Message.id` 列表，可为空）。Session 入队成功时也会广播同名事件，但 payload 是 `message_id` + `content` + `deliver_as`（**名字是 injected，时机是 enqueued**）。UI 用 `message_ids` 列表删除 pending，用单独的 `message_id`（无 `message_ids`）当作入队确认 | 运行中候选消息入队或被并入上下文 |
| `run_end` | Turn / Runner / Runtime | `status`、`turns`、`usage`，出错时 `error` | 见下方 `status` 取值 |
| `agent_end` | Turn | 与同一时刻的 `run_end` 相同 payload | 紧跟 `run_end` 发出；主要供 `Handbeam.Extension.Event` hook 使用。`TranscriptPersistence` 只走 catch-all flush，`Session` 照常广播但不转发到 `"runtime:runs"` |

`run_end` / `agent_end` 的 `status`：

- 来自 Turn（atom）：`:completed`、`:error`、`:max_turns`、`:budget_exceeded`、`:halted`、**`:interrupted`**（见 `Handbeam.Agent.State` 的 status type）。
- 来自 Runner（string）：`"cancelled"`（`Runner.cancel/1`）、`"error"`（task crash，`finish_error/2`，`turns: 0`）。
- 来自 `Handbeam.Runtime.mark_interrupted_runs/0`（string）：`"interrupted"`，用于宿主重启后把仍标记 `running?` 的 session 收尾。
- 消费方必须同时接受 atom 与 string（`WorkspaceLive.safe_atom/1`、`TaskTracker.waiting_status?/1` 都是这么做的）。

**`status: :interrupted` 不是终态。** 工具审批流程：

1. Turn 发 `tool_approval_requested`，随后 `finish_run/2` 发 `run_end` + `agent_end`（`status: :interrupted`），loop 返回带 `interrupt_data` 的 `State`。
2. `Runner` 收到 `%State{status: :interrupted}` 后进入 `:awaiting_approval`，保留 `interrupted_state`，**不** seal queue、**不** `mark_run_finished`、**不**停 RunSupervisor。
3. `Runner.resume/2` 传入 decisions（`%{"tool_call_id", "tool_name", "action" => "approve" | "deny", "remember"}`）→ `Handbeam.Agent.resume_after_tool_approval/3` → 继续 loop，之后再发一次真正终态的 `run_end`。
4. `WorkspaceLive` 只在 `status not in [:interrupted]` 时清 `pending_approval`；`TaskTracker` 把 `interrupted`/`awaiting_approval` 视为 waiting 而非 finish。
5. `Session.maybe_broadcast_run_lifecycle/2` 只把 `run_start`、`run_end`、`tool_approval_requested` 三种转发到 `"runtime:runs"` topic（`{:run_lifecycle, session_id, kind, payload}`），`TaskTracker` 订阅的是这个。

`Handbeam.EventRecorder` 只落盘 `run_start`、`tool_start`、`tool_end`、`run_end`、`error`；`Handbeam.PubSub.AgentEvent` 的 `@type kind` 目前没有列 `tool_approval_requested`/`agent_end`/`turn_*`，但 `Session.broadcast_event/3` 不校验 kind，实际会广播。

### Transcript entry 字段（`messages.jsonl`）

写入方只有 `Handbeam.Agent.TranscriptPersistence`。所有 entry 共有 `base_entry/2` 字段：`conversation_id`、`run_id`、`channel`、`source`、`delivery_ref`、`metadata`（`workspace_id`/`model`/`source` 的字符串化子集）。

| 种类 | `content_type` / `message_type` / `role` / `direction` | 专有字段 |
|------|------|------|
| inbound user | `user_msg` / `user` / `user` / `inbound` | `id`（`opts[:transcript_id]` / `opts[:inbound_id]` / `opts[:message_id]` 应对齐为同一值）、`content`（纯文本）、`attachments`、`raw_content`、`inbound_id`、`delivery`（`"new_run"` / `"steer"` / `"follow_up"`）、`interrupts_work`（仅 `"steer"` 为 true） |
| assistant | `assistant_msg` / `assistant` / `assistant` / `outbound` | `id`（`msg-assistant-*`）、`content`（累计文本）、`status`：`streaming` → `completed`、`phase`：`commentary`（被 tool_start 截断）或 `final` |
| tool | `tool` / `tool` / `tool` / `internal` | `id`（`tool-<tool_use_id>`）、`tool_use_id`、`tool_name`、`tool_status`（`running`/`done`/`error`/`cancelled`）、`input`、`started_at`、`tool_duration_ms`、`tool_error`、`output`、`details`、`file_path`、`diff_lines` |
| run error | `system_msg` / `error` / `system` / `outbound` | `id`（`msg-system-*`）、`content`（`"Run error: ..."`）、`status: "final"` |

inbound 附件相关字段：

- `inbound_id`：`opts[:inbound_id]`，缺省回落到 `opts[:transcript_id]`。宿主（Android 分享/上传）用它做投递确认：`Handbeam.Attachments.inbound_ack/2` 在 `entries` 中匹配 `inbound_id` 或 `id`，返回 `:acknowledged | :unknown`。
- `attachments`：`opts[:attachments]` 经 `Handbeam.Attachments.persistable/1` 规范化后的 list，每项只保留非 nil 的 `id`、`kind`（`"image"`/`"text"`）、`mime_type`、`filename`、`size_bytes`、`relative_path`（相对 workspace 的 `.handbeam/uploads/<conversation_id>/...`）、`source`、`url`。**不存 base64、不存 `content://` URI**；历史恢复由 `Handbeam.Attachments.History.to_messages/2` 按 `relative_path` 重新读文件。
- `raw_content`：有附件时是 `%{"text", "attachments"}`；否则是去掉 `data`/`uri` 的 content block list 或原字符串。

工具字段兼容读取：

- `TranscriptPersistence` 与工具投影只写 `tool_name` / `tool_status` / `tool_duration_ms` / `tool_error`，不再双写旧字段。
- Web 与 native 读方统一使用 `Handbeam.TranscriptEntry`；旧 `messages.jsonl` 的 `tool` / `status` / `duration_ms` / `error` 仍可读取。canonical 键存在时优先，即使值为 nil，也不复活旧 error。
- assistant/system 的 `status` / `error` 不受影响。新增读方不得再引入 `a || b` 别名链。
- Journal 的 retry intent、自动 compaction、分页和跨 VM 原生锁契约见 `docs/transcript-durability.md`。不要直接逐行解析 journal 当作 timeline，也不要删除 `.handbeam-storage.lock` 绕过锁。

### Delivery

- `Handbeam.Delivery` 是 outbound 投递边界。
- 默认 adapter 是 no-op；测试里可传 `delivery:` 和 `delivery_opts:`。
- SNS/Webhook-like 入口应在 Coordinator opts 中携带：
  - `source: :sns` 或 `:webhook`
  - `channel: :sns` 或 `:webhook`
  - `delivery: SomeAdapter`
  - 必要的 `delivery_opts`
- assistant outbound text 在 transcript 持久化后经 `Handbeam.Delivery.deliver/2` 投递回来源 channel。
- LiveView 不通过 Delivery 投递，它通过 PubSub Session projection 更新。

### 常见 bug 排查路径

- UI 没显示，但标题/日志显示 LLM 成功：
  1. 看 `Handbeam.Agent.Runner`/`Turn` 是否有 `message_delta` 或 final message。
  2. 看 `Handbeam.Agent.TranscriptPersistence` 是否写入 `messages.jsonl`。
  3. 看 `WorkspaceLive` 是否从 `ConversationTranscriptStore.list/2` 读到了 transcript。
  4. 最后看 LiveView stream/projection 渲染。
- UI 出现重复字/重复 delta：
  1. 看是否有多个 LiveView 订阅同一 session。
  2. 看 `restore_active_session_snapshot/1` 是否重复 replay 已经持久化的 delta。
  3. 确认没有 UI 和 runtime 同时写同一条 transcript。
- 热重载/切换会话后消息消失：
  1. 先看 `messages.jsonl` 是否有 transcript。
  2. 再看 `sync_conv_state(reload?: true)` / `sync_conv_from/2` 是否从 `ConversationTranscriptStore` 读取。
  3. 确认没有 `ConversationStore.upsert` 用旧 timeline 覆盖 messages。
- SNS/Webhook 收不到 LLM 回复：
  1. 确认入口 opts 有 `source/channel/delivery/delivery_opts`。
  2. 确认 assistant outbound transcript 已写入。
  3. 看 `Handbeam.Delivery.deliver/2` adapter 返回值和日志。
- Token 统计为 0：
  1. 看 provider response usage parse。
  2. 看 `Turn.run_loop/2` 的 `run_end` payload 是否包含 usage。
  3. 看 `WorkspaceLive.usage_tokens/1` 是否读取了对应字段。

## 关键入口

- `Handbeam.Agent.Coordinator.add_message/3` — 运行生命周期门面（LiveView / CLI / webhook 统一入口）
- `Handbeam.Agent.run/2` — 启动 agent 会话
- `Handbeam.Agent.Turn.run_loop/2` — agent loop 纯函数
- `Handbeam.Agent.Runner` — 单次 agent 运行的 GenServer owner
- `Handbeam.Agent.RunSupervisor` — per-conversation 运行监督树（Queue + Runner，one_for_all）
- `Handbeam.AgentRunSupervisor` — DynamicSupervisor，管理所有 RunSupervisor
- `Handbeam.Tool.Registry` — 工具注册中心 (GenServer)
- `Handbeam.MCP.bootstrap/1` — MCP 服务器启动与工具注册
- `Handbeam.PubSub.Session` — 会话管理 (事件快照 + 回放)
- `Handbeam.EventRecorder` — JSONL 事件记录器
- `Handbeam.SessionStore` — 会话持久化 behaviour
- `Handbeam.ConversationTranscriptStore` — conversation transcript 持久化边界
- `Handbeam.Agent.TranscriptPersistence` — runtime event → transcript 写入
- `Handbeam.Delivery` — outbound channel delivery 边界
- `HandbeamWeb.WorkspaceLive` — Web 工作台 LiveView

## 技术栈

- **语言**: Elixir 1.20 (rc.5) / Erlang OTP 28
- **框架**: Phoenix 1.8.7 / LiveView 1.1
- **数据库**: SQLite3 (ecto_sqlite3)
- **HTTP**: Req ~> 0.5
- **文件搜索**: ex_fff (ETS 三元组模糊索引)
- **Provider**: Anthropic Claude / OpenAI / DeepSeek / ZenMux / OpenRouter / StepFun

## 数据存储边界

- SQLite 当前只承载 Memory 系统，不是对话/工作区的主存储。
- Ecto Repo: `Handbeam.Repo`，开发库路径为项目根目录 `handbeam_dev.db`，测试库为 `handbeam_test.db`；生产库由 `DATABASE_PATH` 指定。
- 当前迁移只创建 `engrams` 与 `synapses` 两张业务表：
  - `engrams` 存记忆条目（fact / pattern / preference / rule / context），schema 位于 `lib/handbeam/memory/engram.ex`。
  - `synapses` 存记忆条目之间的关联，schema 位于 `lib/handbeam/memory/synapse.ex`。
- 记忆读写入口是 `Handbeam.Memory.MemoryStore` 以及 `mem_recall` / `mem_learn` / `mem_reinforce` / `mem_associate` 工具。
- 截至 2026-05-16，本地 `handbeam_dev.db` 与 `handbeam_test.db` 中 `engrams = 0`、`synapses = 0`，只有 `schema_migrations = 1`；即数据库结构已迁移，但没有实际记忆数据。
- 对话与工作区不是存在 SQLite 里：
  - `Handbeam.ConversationStore` 使用 JSON/JSONL 文件，固定目录为 `~/.handbeam/conversations/`。
  - `Handbeam.ConversationTranscriptStore` 是对话消息的逻辑边界；当前底层仍写 `ConversationStore` 的 `messages.jsonl`。
  - `Handbeam.WorkspaceStore` 使用 JSON 文件，默认路径 `~/.handbeam/workspaces.json`。
  - `Handbeam.SessionStore.File` 使用 JSON 文件，默认路径 `~/.handbeam/sessions/`；`workspace_path` 不影响 session 存储位置。
- `SessionStore.File` 保存的是 runtime snapshot/replay，不是用户可见 conversation transcript。
- `WorkspaceLive` 的 `timeline` 是 UI projection 名称，不是持久化 owner。
- `Handbeam.Log.Store` 是进程内 Agent 存储，不自动持久化到 SQLite。

### 持续存储文件清单

对话存储是全局统一存储，和工作区配置文件不是同一层：

```text
~/.handbeam/conversations/
├── index.json
└── items/
    └── <conversation_id>/
        ├── meta.json
        ├── messages.jsonl
        └── files.json
```

- `index.json`：conversation 列表索引，包含 `id`、`workspace_id`、`title`、`title_source`、`archived_at`、`created_at`、`updated_at` 等元信息。
- `items/<conversation_id>/meta.json`：单个 conversation 的元信息。
- `items/<conversation_id>/messages.jsonl`：用户可见 transcript，包含 user / assistant / tool / error / change 等 timeline entry。历史对话恢复应以它为事实来源。
- `items/<conversation_id>/files.json`：该 conversation 的编辑器文件状态、当前文件、文件预览错误等 UI 辅助状态。

工作区存储只保存工作区配置，不保存 conversation transcript：

```text
~/.handbeam/workspaces.json
```

- `workspaces.json`：workspace 列表，包含 `id`、`name`、`path`、`default`、`added_at`、`last_opened_at` 等配置。
- `HANDBEAM_WORKSPACES_FILE` 只允许影响 workspace 配置文件位置，不允许影响 conversation 存储位置。
- 不要从 workspace 文件路径推导 conversation 目录。

Runtime session snapshot/replay 存储：

```text
~/.handbeam/sessions/<session_id>.json
```

- 默认写 `~/.handbeam/sessions/`。
- `workspace_path` 不允许改变 session 存储位置。
- 测试或特殊调用可以显式传 `session_store_dir`，但产品默认路径仍是 `~/.handbeam/sessions/`。
- 这里保存的是运行态快照和 replay 信息，不是用户可见对话历史；不能用它替代 `messages.jsonl`。

事件审计/调试日志：

```text
~/.handbeam/events/<session_id>.jsonl
```

- 默认写 `~/.handbeam/events/`。
- `workspace_path` 不允许改变 events 存储位置。
- 测试或特殊调用可以显式传 `event_dir`，但产品默认路径仍是 `~/.handbeam/events/`。
- 当前记录 `run_start`、`tool_start`、`tool_end`、`run_end`、`error` 等事件。

工作区本地设置文件：

```text
<workspace_path>/.handbeam/
```

- 工作区目录下 `.handbeam/` 只保存 workspace-local 配置和该工作区的 Memory SQLite 文件。
- Memory SQLite 是“这个工作区的记忆”，不是全局 conversation transcript。
- 不要把全局 conversation index 放到工作区 `.handbeam/` 下。
- 不要把 runtime session snapshot 或 events 放到工作区 `.handbeam/` 下。

热重载/历史丢失类问题排查时，必须同时区分两种现象：

- “绝对路径 `~/.handbeam/conversations/index.json` 被删除或覆盖”。
- “当前代码解析到的 conversation index 不是 `~/.handbeam/conversations/index.json`，所以看起来像 index 不存在”。

如果看到 index “消失”，先用绝对路径检查：

```bash
ls -la ~/.handbeam/conversations/index.json
find ~/.handbeam/conversations/items -maxdepth 2 -type f
```

不要只相信日志里某个动态解析出来的 index 路径。

### 工具一览

| 分类 | 工具名 | 功能 |
|------|--------|------|
| Builtin | `read` | 读取文件（分页、二进制检测） |
| Builtin | `edit` | 精确文本替换（old_string → new_string） |
| Builtin | `write` | 创建/覆盖文件 |
| Builtin | `bash` | 执行 Shell 命令（超时、工作目录）。`Host.shell?` 为 false 的主机（手机）不注册；不嗅探 `MOB_DATA_DIR` |
| Builtin | `browser` | 桌面包装 `agent-browser`；手机走独立 WebView session（`action` schema） |
| Builtin | `preview_serve` | 登记静态目录或 loopback 端口，对话卡片打开 PreviewShell |
| Builtin | `android_open_url` | `Host.system_intents?` 主机：系统浏览器打开 http(s)；不是 Agent WebView |
| Builtin | `android_open_file` | `Host.system_intents?` 主机：固定 ExportSnapshot 后用系统应用打开产物 |
| Builtin | `android_share_file` | `Host.system_intents?` 主机：固定 ExportSnapshot 后打开系统分享界面 |
| Builtin | `run_elixir_script` | `Host.system_intents?` 主机（手机）：执行工作区 `.exs`（`args`/`workspace` 绑定，非沙箱） |
| Builtin | `mix_project` | Mix/Hex 项目：deps.get / compile / test / run。纯 Elixir/Erlang 包；NIF/外部构建明确报错。单一 MixOwner 串行化并恢复 VM cwd |
| Builtin | `file_search` | 模糊文件搜索（ex_fff，typo-tolerant） |
| Memory | `mem_recall` | 记忆检索 |
| Memory | `mem_learn` | 记忆学习（短期 → 长期） |
| Memory | `mem_reinforce` | 记忆强化 |
| Memory | `mem_associate` | 记忆关联 |
| BEAM | `ext__beam__docs` | 模块/函数文档查询 |
| BEAM | `ext__beam__source` | 源码位置定位 |
| BEAM | `ext__beam__sql` | Ecto Repo SQL 查询 |
| BEAM | `ext__beam__eval` | 隔离进程执行代码（AST 限制不是安全沙箱） |
| BEAM | `ext__beam__schemas` | Ecto Schema 发现 |
| BEAM | `ext__beam__sup_tree` | 监督树可视化 |
| BEAM | `ext__beam__top` | 进程排名（内存/归约/消息队列） |
| BEAM | `ext__beam__process_info` | 进程深度检查 |
| MCP | `mcp__<server>__<tool>` | 外部 MCP 服务器工具（动态注册） |

> BEAM 工具通过 ExtensionBridge 动态注册。Elixir 项目自动检测（检查 working_directory 是否有 mix.exs），非 Elixir 项目不暴露 BEAM 工具。eval 不自动注册，需显式调用。`ext__beam__eval` 的 AST 黑名单不是沙箱；手机脚本执行走 `run_elixir_script`（`Host.system_intents?`，未声明时回落到 `Host.webview_browser?`），在宿主 BEAM 上高权限运行。
>
> 主机门控的工具种子只有一处：`Handbeam.Tool.Registry.host_tool_modules/0`（`Handbeam.Agent.default_tools/0` 直接调它）。主机注入点：`:host` map（`Handbeam.Host.put!/1`，含 `system_intents` / `directory_picker`）、`Application.get_env(:handbeam, :android_intent)`（出站系统 Intent）、`Application.get_env(:handbeam, :notifier)`（运行通知，`Handbeam.Runtime.AndroidNotify`）。`sigil` 不 `Process.whereis` 任何 probe 进程名。
>
> `Handbeam.Extension.HotReloader` 在 dev/prod 启动时先扫一遍已有扩展，并监听 `{cwd}/.handbeam/extensions` 和 `~/.handbeam/extensions`。文件变化 debounce 后 `reload/1`：`Code.compile_file` 成功才覆盖注册 `ext__*`、挂 `handle_event/2` hook、调和 `child_spec/1` 子进程。同名 worker **保留 pid**（只换模块代码，不丢 GenServer state）；编译失败不碰 Registry / 进程。不杀正在跑的 `RunSupervisor`。对话里 `write`/`edit` 落到任意 `{workspace}/.handbeam/extensions` 也会 `notify_path`。内存先试：`ext__mount__apply` / `ext__mount__drop`（`compile_string`，不写盘）。定时任务不属于 Handbeam 内核，需由对话生成普通扩展后通过热插拔接入。测试环境默认 `extension_hot_reload: false`。显式调用：`Handbeam.Extension.HotReloader.reload(project: path)`。

## 常用命令

```bash
mix compile           # 编译
mix format            # 格式化
mix test              # 测试
mix test --dry-run    # 列出测试但不执行 (1.20+)
mix phx.server        # 启动开发服务器
iex -S mix phx.server # 启动 + IEx 交互
mix ecto.migrate      # 数据库迁移
mix precommit         # 提交前检查
```

### Elixir 1.20 新增开发命令

| 命令 | 用途 | Agent 场景 |
|------|------|-----------|
| `mix source MODULE` | 打印或打开模块/函数源码位置 | 快速定位模块定义位置，替代 `elixir_source` |
| `mix test --dry-run` | 列出所有测试而不执行 | 生成测试清单、了解测试覆盖范围 |
| `mix format --no-compile` | 不编译直接格式化 | 快速格式化后不触发完整编译 |
| `mix deps.tree --output FILE` | 导出依赖树到文件 | 分析依赖关系 |
| `mix app.tree --output FILE` | 导出应用树到文件 | 分析应用结构 |
| `mix help MODULE` | 在 shell 中显示模块文档 | 快速查阅文档（含 types/callbacks）|
| `IEx.Helpers.source/1` | 在 IEx 中显示源码 | 交互式调试时快速看源码 |

> `mix help` 在 1.20 中已支持打印 types 和 callbacks 文档，Agent 可以通过 `bash "mix help Mod.fun/arity"` 获取精确的 API 文档。

## 开发约定

参考 [ElixirStyleGuide.md](./ElixirStyleGuide.md)

- 不可变数据、显式管道、信任 BEAM
- SnAkE_cAsE 文件名 / PascalCase 模块名
- 谓词函数以 `?` 结尾，危险函数以 `!` 结尾
- Changeset 优先，`:ok/:error` tuple 模式
- 禁止 `IO.inspect`，用 `dbg/2`
- 禁止 `Process.sleep` 掩盖并发问题
