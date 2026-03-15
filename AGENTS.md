# Agent 工作规则（Rayman）

本仓库使用 Rayman 规则体系约束 Codex/Copilot 的行为。
canonical 文件名为 `AGENTS.md`（兼容读取 `agents.md`）。


## Skills（自动建议）

启动 Rayman 后，会自动生成 `./.Rayman/context/skills.auto.md`，其中包含基于仓库文件类型与最近日志推断出的 **建议 skills/工具链**。

- 你在开始任何产物生成/调试前，**必须先阅读** `./.Rayman/context/skills.auto.md` 并按其建议选择合适的工具（例如 pdfs/docs/spreadsheets/slides 等）。
- 如需覆盖自动选择：使用环境变量 `RAYMAN_SKILLS_FORCE=pdfs,docs,...`；关闭自动选择：`RAYMAN_SKILLS_OFF=1`。

<!-- RAYMAN:MANDATORY_REQUIREMENTS_V161 -->
## 强制 Requirements 规则（必须遵守）

1. 你 **必须** 先阅读并严格遵守 `.<SolutionName>/.<SolutionName>.requirements.md`。
2. `.<SolutionName>.requirements.md` **必须包含** 全部 `.<SolutionName>/.<ProjectName>/.<ProjectName>.requirements.md`（项目级 requirements）。
3. 当你的代码修改或测试执行 **涉及某个 Project** 时，你 **必须** 执行并遵守该 Project 的 requirements。
4. 若 requirements 存在冲突或不清晰之处，你必须停止并报告冲突点，等待指示后再继续。

专有名词保留英文：Agent / Codex / Copilot / Solution / Project。
<!-- /RAYMAN:MANDATORY_REQUIREMENTS_V161 -->

## 审批模式（full-auto）

- 本仓库默认 **full-auto**：Codex/Copilot 的修改视为已批准，无需向用户二次确认。
- 但必须保证：改动可回滚（建议先创建备份分支/提交），并提供清晰的验证步骤与回滚方式。

## 发布纪律（必须遵守）

- 必须遵守 `.Rayman/RELEASE_REQUIREMENTS.md`：问题闭环后才允许停止/发布；不得破坏既有入口；发布前执行随机抽查与回归守护。
