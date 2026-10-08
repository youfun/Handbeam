# 更新日志 (CHANGELOG)

## [0.2.6] - 模型设置与文件变更预览

### 新增与改进
- 新增供应商时不再要求同时添加模型；Provider ID 留空时自动生成，可在保存供应商后拉取或添加模型。
- 添加供应商和模型时按 llm_db 目录补齐默认信息；升级 llm_db 至 `2026.10.0`，推理等级按模型目录提供，包括 GPT-6.1-Sol。
- iOS 侧载 IPA 打包流程增加 ish-arm64 静态库构建与链接，并为 guest NIF 配置编译参数。
- 点击助手消息中的本地文件链接，在当前聊天区域展开并定位到该消息之前最近一次对应的变更卡片；同时展开折叠的工具记录组，复用带行号和增删颜色的预览。

### 修复
- UI 语言偏好保存到现有 SQLite 数据库的 `ui_settings` 表，重启或新建浏览器会话后恢复已保存的中文或英文，不再被旧 session 或浏览器语言覆盖。
- 切换界面语言时保留 UI 设置页、工作区和会话参数。
- 补齐模型设置中「拉取模型」「全部关闭」「启用」及模型启用说明的英文翻译。
- 恢复历史对话时读取保存的文件变更快照，修复展开预览内容为空、已有文件误标为「已创建」的问题；缺失快照时保留可用差异并禁用回滚。
- 文件差异折叠未变更代码后，行号继续按原文件位置计算。

### 版本
- Handbeam 与 Handbeam Probe 升至 `0.2.6`。
- 构建号升至 `10`。

## [0.2.5] - 模型目录拉取

### 新增与改进
- OpenAI 兼容和 Responses 供应商可以从 `GET /v1/models` 拉取模型，并用 llm_db 补名称、上下文和推理信息。
- WebUI 与 Android 模型设置增加「拉取模型」。Android 模型列表改为紧凑行，不再一模型一张大卡片。

### 版本
- Handbeam 与 Handbeam Probe 升至 `0.2.5`。
- 构建号升至 `9`。

## [0.2.2] - 打包发布

### 版本
- Handbeam 与 Handbeam Probe 升至 `0.2.2`。
- Android `versionCode` 升至 `6`，iOS `CFBundleVersion` 升至 `5`，macOS `CFBundleVersion` 升至 `3`。
- 打 `v0.2.2` 标签触发 Pack。`0.2.1` 只提交到 `dev`，没有对应标签。

## [0.2.1] - macOS 原生客户端

### 新增与改进
- 新增基于系统 WebKit 的 macOS 原生客户端，内置 OTP release，使用随机 loopback 端口启动本机服务。
- `Pack` workflow 在 macOS ARM64 构建中同时生成 Web UI tarball 与 `Handbeam-macos-arm64.zip`，并发布 SHA-256 校验文件。
- macOS 标题栏提供原生导航、工作区面板和设置操作，Web 页面不再重复显示面板控制。
- 启动时侧栏仅加载会话元数据，异常恢复仅检查运行中标记的会话，不再扫描全部历史 transcript。
- 更新 Markdown、Mermaid、DOMPurify 与测试 DOM 依赖，`npm audit` 无已知漏洞。

### 版本
- Handbeam 与 Handbeam Probe 升至 `0.2.1`。
- Android `versionCode` 升至 `5`，iOS `CFBundleVersion` 升至 `4`，macOS `CFBundleVersion` 升至 `2`。

## [0.2.0] - Web UI 安装包

### 新增
- Web UI 自包含安装包：Linux x86_64、Windows amd64、macOS arm64。解压后运行 `start.sh` 或 `start.bat`，默认 `http://localhost:5008`。
- Windows 包不含浏览器内终端（Ghostty 没有 Windows NIF）。
- Android `versionName` 升到 `0.2.0`，`versionCode` 升到 `4`。iOS 短版本同步为 `0.2.0`。

## [2026-09-22] - 工作区代码索引

### 新增
- `code_search`：在工作区里按符号、路径或已配置的 embeddings 返回路径和行号，内容仍由 `read` 读取。
- 未配置 embeddings 时只做本地 FTS keyword 检索，不把切块发到外部。keyword 未命中或 `index=partial` 不表示仓库里没有这段代码。
- 索引是独立 SQLite，不进 Memory Repo。导入/只读工作区写到 `Host.data_dir()`，不写进工作区副本。
- 工作台底栏不再放终端入口；终端仍从右侧面板打开。

## [2026-09-19] - Handbeam Android 实验版

### 新增与改进
- 产品统一命名为 **Handbeam**，仓库迁至 `youfun/Handbeam`。
- Android APK 按 ABI 分包：`Handbeam-arm64-v8a.apk`（手机）与
  `Handbeam-x86_64.apk`（模拟器 / ChromeOS），版本 `0.1.0`、构建号 `2`。
- Android 集成 ExGit `0.0.4` 的 libgit2 NIF，无需系统 Git CLI；支持本地 Git
  操作及 HTTPS clone/fetch/pull，使用应用 CA 包验证服务器证书。
- 内置 Elixir/OTP 支持实验性的手机端脚本与纯 Elixir/Erlang Mix 项目工作流。
  项目代码运行在应用 BEAM 中，不是独立沙箱。
- 中英文 README 添加 Android 英文聊天主界面真机截图，图片统一放在 `docs/screenshots/`。

### 修复与安全
- 修复从仓库子目录调用 add/reset 时的路径基准错误。
- Git 私有认证改为可信宿主配置的凭据名称，工具不再接受明文密码或 PAT；
  runtime 工具输入及持久化 transcript 复用现有脱敏逻辑。
- 凭据信任边界为 HTTPS 主机，不保证同主机不同端口或仓库路径隔离；
  历史已泄露凭据仍需撤销、更换。
- 主工程 Req 升级至 `0.7.4`；mobile 仍保留自身的 `0.6.3` 锁定。
- 修正 guest Docker 镜像的 Handbeam release 路径。

### 构建与仓库整理
- 对齐 Android 构建所需 Zig 版本与设备 Elixir `1.20.1` 工具链。
- 根目录脚本统一至 `scripts/`；`mobile/script/` 保持移动工程独立边界。
- 停止跟踪一次性重命名程序和旧 iOS 启动错误截图，保留本地文件。
- 新增 Android Git 真机 smoke 脚本，验证本地操作、公开 HTTPS 仓库读取及不可信证书拒绝。

### 已知限制
- 仍为实验性测试版本；LLM 推理依赖配置的 API 服务，不是完全离线 Agent。
- Android Git 已在 arm64 真机验证；私有认证及远端 push 尚未做真机验证，SSH 不支持。
- iOS 尚未完成同等真机验证；本次 Android NIF 接入不代表 iOS Git 已可用。

## [2026-05-20] - Workspace 权限管理与弹窗修复

### 新增功能
- **动态工作区权限控制**: 
  - 在 Web UI 的输入框工具栏左侧新增了权限状态 Pill 按钮。
  - 支持下拉选择三种权限模式：
    - **完整存取 (Auto)**: 自动运行所有工具（相当于之前模式）。
    - **安全模式 (Prompt)**: 运行修改类/命令类等敏感工具前会弹出二次确认窗口。
    - **只读模式 (Deny)**: 拒绝所有写文件或命令执行工具。
  - 权限模式的变更会自动、非破坏性地同步写入对应工作区目录下的 `.handbeam/settings.jsonc` 配置文件，完整保留用户现有的注释和格式。

### 修复 (Bug Fixes)
- **权限弹窗丢失/隐藏问题**:
  - 修复了 `HandbeamWeb.WorkspaceLive` 中 `safe_atom/1` 在遇到 `"interrupted"` 和 `"awaiting_approval"` 状态时会被错误重置为 `:idle` 的 Bug。该修复恢复了在“安全模式”下触发敏感工具时审批确认弹窗（Tool Approval Modal）的正常呈现。
  - 修复了在关闭其他手机弹窗/侧边面板时，没有隐藏权限切换下拉菜单的视觉问题。

### 开发与验证
- 引入了针对 `Handbeam.WorkspaceSettings.update_default_mode/2` 修改配置文件的单元测试，确保修改符合非破坏性预期。
- 引入了 LiveView 交互集成测试，覆盖了下拉菜单展开、点击切换、自动收起、UI 状态同步以及 settings.jsonc 文件的落盘更新验证。
