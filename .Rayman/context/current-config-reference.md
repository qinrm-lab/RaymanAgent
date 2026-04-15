# Rayman 当前配置参考

最后确认时间：`2026-04-15 15:31:25 +08:00`

用途：这份文档记录当前工作区里已经确认可用的 Rayman / Codex 配置基线。以后如果再次报错，先把现场配置和这里逐项对比，再决定是环境漂移、能力退化还是代码问题。

## 参考来源

- `.\.codex\config.toml`
- `.\.rayman.env.ps1`
- `.\.Rayman\runtime\agent_capabilities.report.json`
- `.\.Rayman\runtime\agent_capabilities.report.md`
- `.\.Rayman\runtime\proxy.resolved.json`
- `.\.Rayman\runtime\codex.auth.status.json`
- `.\.Rayman\runtime\memory\status.json`
- `.\.Rayman\runtime\repeat_error_guard.last.json`
- `.\.Rayman\runtime\playwright.ready.windows.json`
- `.\.Rayman\runtime\winapp.ready.windows.json`
- `.\.Rayman\context\repeat-error-catalog.json`
- `.\.vscode\settings.json`

## 检索关键词

- 当前配置参考，故障基线，对照配置，环境漂移
- 重复错误，repeat error，signature_id，防复发守卫
- multi agent，subagents，features.multi_agent，effective=true
- codex 版本差异，version drift，0.120.0，0.119.0-alpha.28
- 代理配置，proxy 7890，ChatGPT 登录，qinrm1
- Agent Memory lexical fallback，embedding_model_unavailable，deps_ready=false

## 工作区基线

- WorkspaceRoot：`E:\rayman\software\RaymanAgent`
- Solution：`RaymanAgent`
- 当前宿主：`windows`
- Workspace trust：`trusted`
- 路径规范化：`native`
- 交互模式：`RAYMAN_INTERACTION_MODE=detailed`

## Codex 执行与绑定

- `.codex/config.toml` 当前配置：`approval_policy="on-request"`，`sandbox_mode="danger-full-access"`
- VS Code 设置 `chatgpt.runCodexInWindowsSubsystemForLinux=false`，因此当前 Codex runtime host 走 `windows`
- Rayman 绑定账号别名：`qinrm1`
- 认证状态：`authenticated`
- 登录方式：`ChatGPT`
- 修复命令基线：`rayman codex login --alias qinrm1`

## 代理与网络

- 当前解析代理来源：`C:\Users\qinrm\AppData\Roaming\Code\User\settings.json`
- `http_proxy=http://127.0.0.1:7890`
- `https_proxy=http://127.0.0.1:7890`
- `all_proxy=http://127.0.0.1:7890`
- `no_proxy=localhost,127.0.0.1,::1`

## 已激活能力

- `openai_docs`：active=`true`
- `web_auto_test`：active=`true`，Playwright ready=`true`
- `winapp_auto_test`：active=`true`，WinApp ready=`true`

## 多 Agent / Subagents 基线

- 运行时报告显示：`requested/supported/effective = true/true/true`
- 当前角色集合：`rayman_explorer`、`rayman_reviewer`、`rayman_docs_researcher`、`rayman_browser_debugger`、`rayman_winapp_debugger`、`rayman_worker`
- 重要差异：
  `.codex/config.toml` 当前仍写着 `features.multi_agent = false`
  但 `agent_capabilities.report.json` 在 `2026-04-15T09:45:38.6309528+08:00` 记录的是 multi-agent `effective=true`
  如果以后遇到 subagent 行为异常，先核对这处“配置文件值”和“运行时能力报告”是否已经漂移

## 自动化就绪状态

- Playwright：`ready=true`
- Playwright 路径结论：Windows 侧摘要就绪，实际准备阶段是 `wsl-ensure`
- WinApp：`ready=true`
- WinApp 当前选中后端：`uia_direct`

## Agent Memory 基线

- Agent Memory runtime：`ready`
- 数据库位置：`.\.Rayman\state\memory\memory.sqlite3`
- 当前检索后端：`lexical`
- `deps_ready=false`
- fallback 原因：`embedding_model_unavailable:OSError`
- 说明：如果以后 memory search 命中效果变差，这里是第一优先级排查点，不一定是业务代码故障

## 版本差异提醒

- `agent_capabilities.report.json` 在 `2026-04-15T09:45:38.6309528+08:00` 记录的 Codex 版本：`codex-cli 0.120.0`
- 本次终端直接执行 `codex --version` 于 `2026-04-15T15:31:25.5174035+08:00` 返回：`codex-cli 0.119.0-alpha.28`
- 当前 `codex.exe` 解析路径：
  `C:\Users\qinrm\.vscode\extensions\openai.chatgpt-26.5409.20454-win32-x64\bin\windows-x86_64\codex.exe`
- 这说明“运行时报告版本”和“当前 shell 实际命令版本”存在差异；以后若出现能力缺失、参数不兼容、subagent/feature 表现异常，先排这个版本漂移

## 后续排障优先顺序

1. 先对比 `.\.codex\config.toml`、`.\.rayman.env.ps1` 和本文件。
2. 再检查 `.\.Rayman\runtime\agent_capabilities.report.json` 是否和本文件的能力状态一致。
3. 若问题涉及联网或登录，优先检查 `proxy.resolved.json` 和 `codex.auth.status.json`。
4. 若问题涉及 memory / 提示回忆效果，优先检查 `.\.Rayman\runtime\memory\status.json` 的 backend 和 fallback 原因。
5. 若问题已经修过但又回来，先检查 `.\.Rayman\runtime\repeat_error_guard.last.json` 和 `.\.Rayman\context\repeat-error-catalog.json`。
6. 若问题涉及 subagents，先确认 Codex 版本差异和 multi-agent effective 状态，而不是直接改业务代码。
