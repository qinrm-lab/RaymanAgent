# Rayman AI 助手自定义指令

当用户在聊天框中输入单个问号（? 或 ？）时，请读取 .Rayman/commands.txt 文件的内容，并将其作为可用命令列表展示给用户。

当用户输入 "初始化" 或 "运行 setup" 时，请运行 .Rayman/setup.ps1 脚本来初始化环境。

当用户输入 "WSL 安装依赖" 或 "安装 WSL 依赖" 时，请运行 .Rayman/scripts/utils/ensure_wsl_deps.ps1 脚本，它会在 Ubuntu(WSL2) 中自动安装 pwsh、通知与语音依赖（需要 sudo 密码）。

当用户输入 "Windows 依赖检查" 或 "安装 Windows 依赖" 时，请运行 .Rayman/scripts/utils/ensure_win_deps.ps1 脚本，检查并提示 Windows 侧常用工具（如 git/wsl/dotnet/node/python）。

当用户输入 "保存状态" 或 "暂停" 时，请运行 .Rayman/scripts/state/save_state.ps1 脚本，它会生成 Markdown 状态并自动执行 Git Stash 暂存代码。
当用户输入 "继续" 时，请运行 .Rayman/scripts/state/resume_state.ps1 脚本，它会恢复 Git Stash 并清理状态文件。

当用户输入 "自愈" 或 "测试并修复" 时，请运行 .Rayman/scripts/repair/run_tests_and_fix.ps1 脚本。如果报错，请读取 .Rayman/state/last_error.log 并自动尝试修复代码。

当用户输入 "更新上下文" 时，请运行 .Rayman/scripts/utils/generate_context.ps1 脚本。在执行复杂任务前，请优先读取 .Rayman/CONTEXT.md 了解项目结构。

当用户输入 "拷贝后自检"、"拷贝初始化自检" 或 "自检初始化" 时，请运行 .Rayman/rayman.ps1 copy-self-check，用于验证 .Rayman 拷贝到新项目后是否能成功初始化。

当用户输入 "严格自检"、"出厂验收" 或 "严格模式自检" 时，请运行 .Rayman/rayman.ps1 copy-self-check --strict，用于执行包含 Release Gate 的一键出厂验收。

当用户输入 "严格自检保留现场" 或 "出厂验收保留现场" 时，请运行 .Rayman/rayman.ps1 copy-self-check --strict --scope wsl --keep-temp --open-on-fail，用于失败后自动保留并打开临时验收目录。

当用户输入 "停止监听" 或 "停止后台服务" 时，请运行 .Rayman/scripts/watch/stop_background_watchers.ps1 脚本来停止所有后台监听进程。

当用户输入 "清理缓存" 或 "一键清理缓存" 时，请运行 .Rayman/scripts/utils/clear_cache.ps1 脚本。
当用户输入 "一键部署" 时，请运行 .Rayman/scripts/deploy/deploy.ps1 脚本。如果用户指定了项目名（如 "一键部署 WebApp"），请将项目名作为 -ProjectName 参数传递给脚本。

【重要】当你在执行任务过程中，遇到需要用户手动确认、输入信息或进行人机交互时，请务必先运行 .Rayman/scripts/utils/request_attention.ps1 脚本，通过语音提醒用户。你可以通过 -Message 参数传递具体的提示内容，例如：.Rayman/scripts/utils/request_attention.ps1 -Message "需要您确认部署配置"。

【规划增强】当用户的需求较复杂、信息不完整或表述不清晰时：
1) 先自动给出一个简短的可执行计划（分步骤/待办）；
2) 提出最多 3-4 个关键澄清问题；
3) 若用户未回复，按“最小返工”的默认方案继续推进，并在关键分歧点再次确认。

【模型与输出策略】
- 优先使用用户选择的模型。如果不可用，请自动降级选择当前可用的最强模型（如 Claude 3.5 Sonnet, GPT-4o, Gemini 1.5 Pro 等）。
- 忽略 Token 消耗限制，提供最完整、最深入的代码实现和架构分析。
- 严禁在生成代码时使用 // ...existing code... 或类似占位符省略逻辑，必须输出完整的、可直接运行的代码块。
