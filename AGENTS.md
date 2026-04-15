# Agent 工作规则（Rayman）

本仓库使用 Rayman 规则体系约束 Codex/Copilot 的行为。
canonical 文件名为 `AGENTS.md`（兼容读取 `agents.md`）。


## Skills（自动建议）

启动 Rayman 后，会自动生成 `./.Rayman/context/skills.auto.md`，其中包含基于仓库文件类型与最近日志推断出的 **建议 skills/工具链**。

- 你在开始任何产物生成/调试前，**必须先阅读** `./.Rayman/context/skills.auto.md` 并按其建议选择合适的工具（例如 pdfs/docs/spreadsheets/slides 等）。
- 如需覆盖自动选择：使用环境变量 `RAYMAN_SKILLS_FORCE=pdfs,docs,...`；关闭自动选择：`RAYMAN_SKILLS_OFF=1`。

## Codex subagents（Rayman 默认能力层）

- Rayman 会把 Codex 的 `subagents` 作为默认能力层的一部分管理，`.codex/config.toml` 同时承载 MCP 配置，以及 Rayman-managed 的 `project_doc`、`profiles`、`subagents` slice。
- 角色集合固定为：`rayman_explorer`、`rayman_reviewer`、`rayman_docs_researcher`、`rayman_browser_debugger`、`rayman_winapp_debugger`、`rayman_worker`。
- `.github/agents/*.agent.md`、`.github/skills/*/SKILL.md`、`.github/prompts/*.prompt.md` 是 Rayman 共享给 Codex/Copilot 的 capability 资产；修改时必须与 `dispatch`、`review_loop`、capability report 保持一致。
- Codex 只有在任务或提示中被显式要求时才会起 subagent；Rayman 的 `dispatch` 和 system instructions 会显式点名应委派的角色与触发条件。
- 若当前环境不支持 multi-agent，Rayman 保留 MCP / 单代理流程，并把 `supported`、`effective`、`degraded_reason` 和角色状态写入 report/context 方便追踪。
- GitHub.com 的 Copilot Memory、model picker / Auto model selection 属于平台能力；Rayman 只负责文档和检测，不在仓库内伪装成已托管能力。

<!-- RAYMAN:MANDATORY_REQUIREMENTS_V165 -->
## 强制 Requirements 规则（必须遵守）

1. 你 **必须** 先阅读并严格遵守 `.<SolutionName>/.<SolutionName>.requirements.md`。
2. `.<SolutionName>.requirements.md` **必须包含** 全部 `.<SolutionName>/.<ProjectName>/.<ProjectName>.requirements.md`（项目级 requirements）。
3. 当你的代码修改或测试执行 **涉及某个 Project** 时，你 **必须** 执行并遵守该 Project 的 requirements。
4. 若 requirements 存在冲突或不清晰之处，你必须停止并报告冲突点，等待指示后再继续。

专有名词保留英文：Agent / Codex / Copilot / Solution / Project。
<!-- /RAYMAN:MANDATORY_REQUIREMENTS_V165 -->

## 审批模式（full-auto）

- 本仓库默认 **full-auto**：Codex/Copilot 的修改视为已批准，无需向用户二次确认。
- `full-auto` 只表示改动审批已放行，不表示可以替用户决定需求，或在存在多条有意义实现路径时自行拍板。
- 但必须保证：改动可回滚（建议先创建备份分支/提交），并提供清晰的验证步骤与回滚方式。
- 在 Windows 上执行审批敏感的 PowerShell 自动化时，优先使用 `powershell.exe -Command` / `-File`；只有明确需要 PowerShell 7 兼容性或非 Windows Host 时才使用 `pwsh`。

## 交互模式（每工作区长期有效）

- 工作区可通过 `.rayman.env.ps1` 中的 `RAYMAN_INTERACTION_MODE=detailed|general|simple` 控制“多路径 / 目标不明确时，先给 plan 还是先执行”。
- 硬门槛：只要 Rayman 判断提示不足够明确，且该歧义会影响目标、范围、实现路径、风险、测试期望、目标工作区或回滚方式，就必须先给出可选方案、说明结果差异，并写出明确验收标准；该要求不依赖 Codex Plan Mode。
- 默认是 `detailed`：
  只要目标不明确、存在明显多路径、或不同方案结果差异明显，就先给出 plan、解释选项和结果、明确验收标准，再继续。
- `general`：
  只在会明显改变结果、范围、实现路径、风险、测试期望或返工成本的歧义上先停下来确认；一旦停下，同样必须给出选项和验收标准；次要细节可带默认假设继续。
- `simple`：
  只在高风险、不可逆、跨工作区、发布/架构级、或明显可能走错方向时先停下来确认；一旦停下，同样必须给出选项和验收标准；其余按推荐默认继续并显式写出假设。
- 上述模式不影响硬门禁：
  跨工作区 target 选择、policy block、release gate、危险操作等仍然必须停下。

## 发布纪律（必须遵守）

- 必须遵守 `.Rayman/RELEASE_REQUIREMENTS.md`：问题闭环后才允许停止/发布；不得破坏既有入口；发布前执行随机抽查与回归守护。
