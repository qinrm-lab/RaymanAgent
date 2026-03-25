# Rayman AI 助手自定义指令

详细编码约定与文件类型规则请优先参考：.github/instructions/general.instructions.md、.github/instructions/backend.instructions.md、.github/instructions/frontend.instructions.md。

复杂任务开始前，请优先读取 .Rayman/CONTEXT.md 与 .Rayman/context/skills.auto.md；若它们缺失或过期，请先运行“更新上下文”。
同时请将 .github/model-policy.md 视为模型与平台能力边界的单一事实来源，并在评估已落地能力与规划项时参考 .Rayman/release/FEATURE_INVENTORY.md 与 .Rayman/release/ENHANCEMENT_ROADMAP_2026.md。

Rayman 会自动生成并维护工作区级 .codex/config.toml；Rayman-managed slice 包括 capability MCP、project_doc fallback、profiles 与 subagents。不要把这些 Codex 专用 capability 混入 .Rayman/mcp/mcp_servers.json。

Rayman 还会维护 .github/agents/*.agent.md、.github/skills/*/SKILL.md 与 .github/prompts/*.prompt.md；它们是 Copilot/Codex 共享的 capability 资产，修改时必须与 dispatch、eview_loop 和 capability report 保持一致。

当任务涉及 OpenAI 产品、API、模型、SDK 或官方文档时，请优先使用 OpenAI Docs MCP，而不是依赖过期记忆。

当任务涉及网页自动化、浏览器排障、页面录制、E2E 或 UI 测试时，请优先使用 Playwright MCP；若当前环境拿不到 MCP，则先走 .Rayman/rayman.ps1 ensure-playwright，失败时再降级到 .Rayman/rayman.ps1 pwa-test。

当任务涉及桌面自动化、UIA、WinForms、WPF 或 MAUI(Windows) 排障 / 测试时，请优先使用 Rayman WinApp MCP；若当前环境拿不到 MCP，则先走 .Rayman/rayman.ps1 ensure-winapp，失败时再降级到 .Rayman/rayman.ps1 winapp-test。

Copilot 环境如果没有等价 MCP，不要伪造能力；按 Rayman 已提供的命令入口做最佳努力降级即可。
GitHub.com 的 Copilot Memory、model picker / Auto model selection 属于平台能力；Rayman 只负责文档和检测，不在仓库内伪装成已托管能力。

当用户在聊天框中输入单个问号（? 或 ？）时，请读取 .Rayman/commands.txt 文件的内容，并将其作为可用命令列表展示给用户。

当用户输入 "初始化" 或 "运行 setup" 时，请运行 .Rayman/setup.ps1 脚本来初始化环境。
setup 默认会准备本地 Git 仓库；交互式场景下会尝试 GitHub 登录并执行 gh auth setup-git，但不会自动创建 remote 仓库。
在 Windows 上执行审批敏感的 PowerShell 自动化时，优先使用 `powershell.exe -Command` / `-File`；只有明确需要 PowerShell 7 兼容性或非 Windows Host 时才使用 `pwsh`。

当用户输入 "WSL 安装依赖" 或 "安装 WSL 依赖" 时，请运行 .Rayman/scripts/utils/ensure_wsl_deps.ps1 脚本，它会在 Ubuntu(WSL2) 中自动安装 pwsh、通知与语音依赖（需要 sudo 密码）。

当用户输入 "Windows 依赖检查" 或 "安装 Windows 依赖" 时，请运行 .Rayman/scripts/utils/ensure_win_deps.ps1 脚本，检查并提示 Windows 侧常用工具（如 git/wsl/dotnet/node/python）。

当用户输入 "保存状态" 或 "暂停" 时，请运行 .Rayman/scripts/state/save_state.ps1 脚本，它会生成 Markdown 状态并自动执行 Git Stash 暂存代码。
当用户输入 "继续" 时，请运行 .Rayman/scripts/state/resume_state.ps1 脚本，它会恢复 Git Stash 并清理状态文件。

当用户输入 "自愈" 或 "测试并修复" 时，请运行 .Rayman/scripts/repair/run_tests_and_fix.ps1 脚本。如果报错，请读取 .Rayman/state/last_error.log 并自动尝试修复代码。

当用户输入 "更新上下文" 时，请运行 .Rayman/scripts/utils/generate_context.ps1 脚本。该脚本会刷新 .Rayman/CONTEXT.md 与 .Rayman/context/skills.auto.md；在执行复杂任务前，请优先读取它们了解项目结构与建议能力。

当用户输入 "拷贝后自检"、"拷贝初始化自检" 或 "自检初始化" 时，请运行 .Rayman/rayman.ps1 copy-self-check，用于验证 .Rayman 拷贝到新项目后是否能成功初始化。

当用户输入 "严格自检"、"出厂验收" 或 "严格模式自检" 时，请运行 .Rayman/rayman.ps1 copy-self-check --strict，用于执行包含 Release Gate 的一键出厂验收。

当用户输入 "严格自检保留现场" 或 "出厂验收保留现场" 时，请运行 .Rayman/rayman.ps1 copy-self-check --strict --scope wsl --keep-temp --open-on-fail，用于失败后自动保留并打开临时验收目录。

当用户输入 "停止监听" 或 "停止后台服务" 时，请运行 .Rayman/scripts/watch/stop_background_watchers.ps1 脚本来停止所有后台监听进程。

当用户输入 "清理缓存" 或 "一键清理缓存" 时，请运行 .Rayman/scripts/utils/clear_cache.ps1 脚本。
当用户输入 "一键部署" 时，请运行 .Rayman/scripts/deploy/deploy.ps1 脚本。如果用户指定了项目名（如 "一键部署 WebApp"），请将项目名作为 -ProjectName 参数传递给脚本。

【重要】当你在执行任务过程中，遇到需要用户手动确认、输入信息或进行人机交互时，请务必先运行 .Rayman/scripts/utils/request_attention.ps1 脚本，通过语音提醒用户。你可以通过 -Message 参数传递具体的提示内容，例如：.Rayman/scripts/utils/request_attention.ps1 -Message "需要您确认部署配置"。

其余通用治理、输出、验证与回滚要求，以 AGENTS.md、.Rayman/CONTEXT.md、.Rayman/README.md 和 .Rayman/config/*.json 为准；避免在本文件重复堆叠长篇规则。
