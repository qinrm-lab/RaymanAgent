# Rayman AI 助手自定义指令

优先级从高到低：

1. `AGENTS.md` 与 `.<SolutionName>/.<SolutionName>.requirements.md`
2. `.github/instructions/general.instructions.md`、`.github/instructions/backend.instructions.md`、`.github/instructions/frontend.instructions.md`
3. `.github/model-policy.md`
4. `.Rayman/CONTEXT.md` 与 `.Rayman/context/skills.auto.md`
5. `.Rayman/release/FEATURE_INVENTORY.md` 与 `.Rayman/release/ENHANCEMENT_ROADMAP_2026.md`

复杂任务开始前，请优先读取 `.Rayman/CONTEXT.md` 与 `.Rayman/context/skills.auto.md`；若它们缺失或过期，请先运行“更新上下文”。

Rayman 会自动生成并维护工作区级 `.codex/config.toml`；Rayman-managed slice 包括 capability MCP、project_doc fallback、profiles 与 subagents。不要把这些 Codex 专用 capability 混入 `.Rayman/mcp/mcp_servers.json`。

Rayman 还会维护 `.github/agents/*.agent.md`、`.github/skills/*/SKILL.md` 与 `.github/prompts/*.prompt.md`；它们是 Copilot/Codex 共享的 capability 资产，修改时必须与 `dispatch`、`review_loop` 和 capability report 保持一致。

`.github/model-policy.md` 只定义 hosted model selection 边界；`.Rayman/release/FEATURE_INVENTORY.md` 与 `.Rayman/release/ENHANCEMENT_ROADMAP_2026.md` 是 review / enhancement 基线，不改变既有 CLI 默认行为。

当任务涉及 OpenAI 产品、API、模型、SDK 或官方文档时，请优先使用 OpenAI Docs MCP，而不是依赖过期记忆。

当任务涉及网页自动化、浏览器排障、页面录制、E2E 或 UI 测试时，请优先使用 Playwright MCP；若当前环境拿不到 MCP，则先走 `.Rayman/rayman.ps1 ensure-playwright`，失败时再降级到 `.Rayman/rayman.ps1 pwa-test`。

当任务涉及桌面自动化、UIA、WinForms、WPF 或 MAUI(Windows) 排障 / 测试时，请优先使用 Rayman WinApp MCP；若当前环境拿不到 MCP，则先走 `.Rayman/rayman.ps1 ensure-winapp`，失败时再降级到 `.Rayman/rayman.ps1 winapp-test`。

Copilot 环境如果没有等价 MCP，不要伪造能力；按 Rayman 已提供的命令入口做最佳努力降级即可。GitHub.com 的 Copilot Memory、model picker / Auto model selection、custom agents UI 属于平台能力；Rayman 只负责文档和检测，不在仓库内伪装成已托管能力。

在 Windows 上执行审批敏感的 PowerShell 自动化时，优先使用 `powershell.exe -Command` / `-File`；只有明确需要 PowerShell 7 兼容性或非 Windows Host 时才使用 `pwsh`。

当用户在聊天框中输入单个问号（`?` 或 `？`）时，请读取 `.Rayman/commands.txt` 并展示可用命令列表。

当用户输入“初始化”或“运行 setup”时，请运行 `.Rayman/setup.ps1`。setup 默认会准备本地 Git 仓库；交互式场景下会尝试 GitHub 登录并执行 `gh auth setup-git`，但不会自动创建 remote 仓库。

当用户输入“更新上下文”时，请运行 `.Rayman/scripts/utils/generate_context.ps1`。该脚本会刷新 `.Rayman/CONTEXT.md` 与 `.Rayman/context/skills.auto.md`。

当用户输入“拷贝后自检”或“严格自检”时，请运行 `.Rayman/rayman.ps1 copy-self-check`；严格模式使用 `--strict`。

当用户输入“停止监听”或“停止后台服务”时，请运行 `.Rayman/scripts/watch/stop_background_watchers.ps1`。

当用户输入“清理缓存”时，请运行 `.Rayman/scripts/utils/clear_cache.ps1`。

当用户输入“一键部署”时，请运行 `.Rayman/scripts/deploy/deploy.ps1`；若用户指定项目名，则透传 `-ProjectName`。

当任务执行过程中需要用户手动确认、输入信息或进行人机交互时，请先运行 `.Rayman/scripts/utils/request_attention.ps1`，再继续等待人工响应。

其余通用治理、输出、验证与回滚要求，以 `AGENTS.md`、`.Rayman/CONTEXT.md`、`.Rayman/README.md` 和 `.Rayman/config/*.json` 为准；避免在本文件重复堆叠长篇规则。
