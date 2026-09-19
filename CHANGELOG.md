# 更新日志 (CHANGELOG)

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
