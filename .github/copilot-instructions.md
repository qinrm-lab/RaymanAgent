# Rayman AI 助手自定义指令

详细编码约定与文件类型规则请优先参考：.github/instructions/general.instructions.md、.github/instructions/backend.instructions.md、.github/instructions/frontend.instructions.md。

复杂任务开始前，请优先读取 .Rayman/CONTEXT.md 与 .Rayman/context/skills.auto.md；若它们缺失或过期，请先运行“更新上下文”。
同时请将 .github/model-policy.md 视为模型与平台能力边界的单一事实来源，并在评估已落地能力与规划项时参考 .Rayman/release/FEATURE_INVENTORY.md 与 .Rayman/release/ENHANCEMENT_ROADMAP_2026.md。
请同时读取当前工作区交互模式：优先看 .Rayman/CONTEXT.md 中的 `Collaboration Preference / 交互偏好`，必要时回读 .rayman.env.ps1 里的 `RAYMAN_INTERACTION_MODE=detailed|general|simple`。
当目标不明确、存在多条有意义的实现路径、或不同方案结果差异明显时，不要自己猜；应按当前交互模式先给出 plan、说明各选项含义/结果/推荐项，并写出明确验收标准，再继续。
硬门槛：只要你判断提示不足够明确，且该歧义会影响目标、范围、实现路径、风险、测试期望、目标工作区或回滚方式，就必须给出选项和明确验收标准；该要求不依赖 Codex Plan Mode。
`full-auto` 只代表改动审批已放行，不代表可以替用户决定需求或在多方案里自行拍板。

Rayman 会自动生成并维护工作区级 .codex/config.toml；Rayman-managed slice 包括 capability MCP、project_doc fallback、profiles 与 subagents。不要把这些 Codex 专用 capability 混入 .Rayman/mcp/mcp_servers.json。

Rayman 还会维护 .github/agents/*.agent.md、.github/skills/*/SKILL.md 与 .github/prompts/*.prompt.md；它们是 Copilot/Codex 共享的 capability 资产，修改时必须与 dispatch、eview_loop 和 capability report 保持一致。

当任务涉及 OpenAI 产品、API、模型、SDK 或官方文档时，请优先使用 OpenAI Docs MCP，而不是依赖过期记忆。

当任务涉及网页自动化、浏览器排障、页面录制、E2E 或 UI 测试时，请优先使用 Playwright MCP；若当前环境拿不到 MCP，则先走 `rayman ensure-playwright`，失败时再降级到 `rayman.ps1 pwa-test`。

当任务涉及桌面自动化、UIA、WinForms、WPF 或 MAUI(Windows) 排障 / 测试时，请优先使用 Rayman WinApp MCP；若当前环境拿不到 MCP，则先走 `rayman.ps1 ensure-winapp`，失败时再降级到 `rayman.ps1 winapp-test`。

Copilot 环境如果没有等价 MCP，不要伪造能力；按 Rayman 已提供的命令入口做最佳努力降级即可。
GitHub.com 的 Copilot Memory、model picker / Auto model selection 属于平台能力；Rayman 只负责文档和检测，不在仓库内伪装成已托管能力。

当用户在聊天框中输入单个问号（? 或 ？）时，请读取 .Rayman/commands.txt 文件的内容，并将其作为可用命令列表展示给用户。

当用户输入 "初始化" 或 "运行 setup" 时，请运行 `rayman init` 来初始化环境。
setup 默认会准备本地 Git 仓库；交互式场景下会尝试 GitHub 登录并执行 gh auth setup-git，但不会自动创建 remote 仓库。
在 Windows 上执行审批敏感的 PowerShell 自动化时，优先使用 `powershell.exe -Command` / `-File`；只有明确需要 PowerShell 7 兼容性或非 Windows Host 时才使用 `pwsh`。

当用户输入 "WSL 安装依赖" 或 "安装 WSL 依赖" 时，请运行 `rayman.ps1 ensure-wsl-deps`，它会在 Ubuntu(WSL2) 中自动安装 `pwsh`、通知与语音依赖（需要 sudo 密码）。

当用户输入 "Windows 依赖检查" 或 "安装 Windows 依赖" 时，请运行 `rayman.ps1 ensure-win-deps`，检查并提示 Windows 侧常用工具（如 git/wsl/dotnet/node/python）。

当用户输入 "保存状态"、"保存状态 <名字>"、"暂停" 或 "暂停 <名字>" 时，请运行 `rayman.ps1 state-save`；优先把名字传给 `-Name`，未提供名字时命令会自动生成 `unnamed-<timestamp>`。
当用户输入 "继续" 时，请先运行 `rayman.ps1 state-list` 列出可恢复的命名会话。
当用户输入 "继续 <名字>" 时，请运行 `rayman.ps1 state-resume`，并把名字传给 `-Name`。
当用户输入 "隔离工作区 <名字>"、"并行工作区 <名字>" 或 "创建 worktree <名字>" 时，请运行 `rayman.ps1 worktree-create`，并把名字传给 `-Name`。

当用户输入 "自愈" 或 "测试并修复" 时，请运行 `rayman.ps1 test-fix`。如果报错，请读取 `.Rayman/state/last_error.log` 并自动尝试修复代码。

当用户输入 "更新上下文" 时，请运行 `rayman.ps1 context-update`。该命令会刷新 `.Rayman/CONTEXT.md` 与 `.Rayman/context/skills.auto.md`；在执行复杂任务前，请优先读取它们了解项目结构与建议能力。

当用户输入 "拷贝后自检"、"拷贝初始化自检" 或 "自检初始化" 时，请运行 `rayman copy-self-check`，用于验证 `.Rayman` 拷贝到新项目后是否能成功初始化。

当用户输入 "严格自检"、"出厂验收" 或 "严格模式自检" 时，请运行 `rayman copy-self-check --strict`，用于执行包含 Release Gate 的一键出厂验收。

当用户输入 "严格自检保留现场" 或 "出厂验收保留现场" 时，请运行 `rayman copy-self-check --strict --scope wsl --keep-temp --open-on-fail`，用于失败后自动保留并打开临时验收目录。

当用户输入 "停止监听" 或 "停止后台服务" 时，请运行 `rayman.ps1 watch-stop` 来停止所有后台监听进程。

当用户输入 "清理缓存" 或 "一键清理缓存" 时，请运行 `rayman.ps1 cache-clear`。
当用户输入 "一键部署" 时，请运行 `rayman.ps1 deploy`。如果用户指定了项目名（如 "一键部署 WebApp"），请将项目名作为 `-ProjectName` 参数传递给命令。

【重要】当你在执行任务过程中，遇到需要用户手动确认、输入信息或进行人机交互时，请务必先运行 `.Rayman/scripts/utils/request_attention.ps1`，通过统一提醒链（声音/提示）提醒用户。你可以通过 `-Message` 参数传递具体的提示内容，例如：`.Rayman/scripts/utils/request_attention.ps1 -Message "需要您确认部署配置"`。

其余通用治理、输出、验证与回滚要求，以 AGENTS.md、.Rayman/CONTEXT.md、.Rayman/README.md 和 .Rayman/config/*.json 为准；避免在本文件重复堆叠长篇规则。
