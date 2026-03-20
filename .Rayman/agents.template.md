# Agent 工作规则（Rayman）

本仓库使用 Rayman 规则体系约束 Codex/Copilot 的行为。

## Codex subagents（Rayman 默认能力层）

- `.codex/config.toml` 同时承载 MCP 配置，以及 Rayman-managed 的 `project_doc`、`profiles`、`subagents` slice，属于 Rayman 生成的工作区级产物。
- 角色集合固定为：`rayman_explorer`、`rayman_reviewer`、`rayman_docs_researcher`、`rayman_browser_debugger`、`rayman_winapp_debugger`、`rayman_worker`。
- `.github/agents/*.agent.md`、`.github/skills/*/SKILL.md`、`.github/prompts/*.prompt.md` 是 Rayman 共享给 Codex/Copilot 的 capability 资产；修改时必须与 `dispatch`、`review_loop`、capability report 保持一致。
- Codex 只有在任务或提示中被显式要求时才会起 subagent；Rayman 的 `dispatch` 和 system instructions 会显式点名应委派的角色与触发条件。
- 若当前环境不支持 multi-agent，Rayman 保留 MCP / 单代理流程，并把状态与降级原因写入 report/context 方便追踪。
- GitHub.com 的 Copilot Memory、model picker / Auto model selection 属于平台能力；Rayman 只负责文档和检测，不在仓库内伪装成已托管能力。

<!-- RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
## 强制 Requirements 规则（必须遵守）

1. 你 **必须** 先阅读并严格遵守 `.<SolutionName>/.<SolutionName>.requirements.md`。
2. `.<SolutionName>.requirements.md` **必须包含** 全部 `.<SolutionName>/.<ProjectName>/.<ProjectName>.requirements.md`（项目级 requirements）。
3. 当你的代码修改或测试执行 **涉及某个 Project** 时，你 **必须** 执行并遵守该 Project 的 requirements。
4. 若 requirements 存在冲突或不清晰之处，你必须停止并报告冲突点，等待指示后再继续。

专有名词保留英文：Agent / Codex / Copilot / Solution / Project。
<!-- /RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
