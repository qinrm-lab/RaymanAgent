# Rayman v161

特点：

- 继承全量能力与最新版实现
- 恢复标准目录形态（含 run/ runtime/ 等）
- **RELEASE_REQUIREMENTS.md 每次都会被强制执行（init/run/CI）**
- `RAYMAN_DEBUG=1` 可开启关键脚本 `set -x`
- `rayman doctor`：一次性跑全链路诊断

## 安装

把 `.Rayman/` 放到仓库根目录：

```bash
bash ./.Rayman/init.sh
```

Windows `setup.ps1` 默认会在初始化完成后自动执行一次 `release-gate -Mode project`（可用 `-SkipReleaseGate` 跳过）。
`setup.ps1` 默认会先准备本地 Git 仓库：若当前工作区还没有 `.git`，会自动执行 `git init`，并尽量把初始分支固定为 `main`。
交互式 `setup` 默认还会尝试 GitHub 登录与 `gh auth setup-git`，用于让当前工作区可以直接使用 Git 远程认证；登录失败默认只告警，不会阻断本地 Git。
`setup.ps1` 不会自动创建远端仓库，也不会自动设置 `origin`。
Git bootstrap 运行结果会写入 `.Rayman/runtime/git.bootstrap.last.json`。
向量库默认写入工作区根目录 `.rag/<命名空间>/chroma_db`（命名空间默认是工作区名）；若检测到已存在，默认会复用并跳过重建，仅在显式传入 `-ForceReindex` 时重建。
若 `setup` 检测到旧路径 `.Rayman/state/chroma_db` 仍有数据且新路径为空，会自动打印迁移命令提示。
`setup.ps1` 无参数时会默认自动迁移旧向量库到新路径；如需关闭可使用 `-NoAutoMigrateLegacyRag`。
外部分发副本在首次 `setup` 后，还会自动补齐工作区根目录 `.rayman.project.json`，并生成标准 workflow：`.github/workflows/rayman-project-fast-gate.yml`、`.github/workflows/rayman-project-browser-gate.yml`、`.github/workflows/rayman-project-full-gate.yml`。RaymanAgent 源仓库不会自动注入这 3 个 consumer workflow。

## 拷贝后源码管理噪声控制（默认开启）

- `setup.ps1` 保留全量资产生成，同时会在末尾自动注入 SCM 忽略规则：外部分发副本默认写入共享的 `.gitignore`，RaymanAgent 源仓库默认写入本地 `.git/info/exclude`。
- 外部分发副本默认会忽略整个 `.Rayman/`、`.SolutionName`、`.rayman.env.ps1`、`.cursorrules`、`.clinerules`、生成的 `.vscode/tasks.json` / `.vscode/settings.json`，以及 `bin/`、`obj/`、`.artifacts/`、`test-results/` 等构建噪声。
- RaymanAgent 源仓库只会默认忽略本地/生成资产，例如 `.Rayman/context/skills.auto.md`、`.Rayman/mcp/*.bak`、`.Rayman/release/*notes*.md`、`.rayman.env.ps1`、`.cursorrules`、`.clinerules`、`.vscode/*`、`.env`、`.codex/config.toml`。
- setup 末尾会输出 `modified/added/untracked/total` 统计；超过软阈值（默认 `100`）时，会提示主要来源目录。
- 若检测到 `.Rayman/**`、`.SolutionName`、`.cursorrules`、`.clinerules`、`.rayman.env.ps1`、`.github/copilot-instructions.md` 已被 Git 跟踪：
  - 外部分发副本会严格阻断，并给出精确 `git rm -r --cached -- ...` 修复命令；这类仓库只建议提交业务源码与 `.<SolutionName>/`。
  - Rayman 源仓库允许 authored `.Rayman/` 与 `.SolutionName`，但仍会阻断本地/生成资产入库。
- 非 Rayman 的常见产物目录（`.dotnet10/`、`dist/`、`publish/`、`.tmp/`、`.temp/`）若被 Git 跟踪，会在 setup / release-gate 中单独告警，但默认不阻断。
- 如需手工覆盖该行为，仍可在工作区级 `.rayman.env.ps1` 中直接设置 `RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1`。

## Doctor（推荐）

```bash
bash ./.Rayman/run/doctor.sh
```

`doctor` 现在会优先执行 `agent-contract`，先确认 agent 资产、instructions、context 与 auto-skills 契约没有漂移，再继续规则与回归检查。

## 自动化测试 Lane

Rayman 现在把自动化测试拆成 4 条 lane，避免所有检查都堆进一个大脚本里：

- `fast-contract`：快速契约检查，覆盖 requirements/layout、release checklist、regression guard、config sanity、agent contract、`.dist` 同步与 JSON contract。
- `logic-unit`：PowerShell `Pester 5` + Bash `bats-core`，优先覆盖路径归一化、scope/fallback、版本 token、WinApp readiness 等容易回归的判定逻辑。
- `host-smoke`：最小真实环境冒烟，重点看 CLI help、`ensure-winapp -Json`、`ensure-playwright -Json` 和 runtime 报告结构。
- `release`：继续由 `release-gate` 负责最终发布门禁，并消费 `.Rayman/runtime/test_lanes/*.report.json` 与 `.Rayman/runtime/project_gates/*.report.json`；缺少 Linux Bash 测试工具时会记为 `WARN`，真实断言失败仍记为 `FAIL`。

## 项目工作流标准化

拷贝 `.Rayman` 到实施工程后，标准入口统一为：

- `rayman fast-gate`：PR 级快速门禁，默认覆盖 requirements layout、protected assets、项目 build、轻量 project smoke，并输出 `.Rayman/runtime/project_gates/fast.report.json`
- `rayman browser-gate`：浏览器/项目冒烟门禁，默认消费 `.rayman.project.json` 的 `browser_command` 与 `extensions.project_browser_checks`
- `rayman full-gate`：完整门禁，先执行项目 release checks，再执行 `release-gate -Mode project`，并输出 `.Rayman/runtime/project_gates/full.report.json`
- `rayman copy-self-check`：分发副本自检；`--strict` 现在除了 SCM tracked-noise 合同，还会验证外部分发副本 setup 后可以跑通标准 `fast-gate`

`.rayman.project.json` 是 consumer repo 的唯一标准项目扩展点，默认保留这些最小参数：

- `build_command`
- `browser_command`
- `full_gate_command`
- `enable_windows`
- `extra_protected_assets_manifest`
- `extensions.project_fast_checks / project_browser_checks / project_release_checks`

Rayman source workspace（例如 `RaymanAgent` 自身）不会强制要求这些 consumer-only 命令；当 `fast/browser/full gate` 遇到未配置项时，会显式记为 `SKIP`，而不是提示为待补齐的 `WARN`。

workflow 模板默认统一 Chromium 为浏览器基线；项目如有其他浏览器需求，应在自身 `browser_command` 中显式声明。

本地入口：

```bash
bash ./.Rayman/scripts/testing/run_fast_contract.sh
bash ./.Rayman/scripts/testing/run_bats_tests.sh
pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/testing/run_pester_tests.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/scripts/testing/run_host_smoke.ps1
```

依赖说明：

- JSON contract 校验依赖 `python + jsonschema`
- Bash 逻辑单测依赖 `bats-core`
- PowerShell 逻辑单测依赖 `Pester 5`

CI 约定：

- PR / push 走 hosted matrix：`ubuntu-latest` + `windows-latest`
- nightly / manual 额外跑深度 smoke
- self-hosted 深度 smoke 约定 runner labels：`self-hosted`, `windows`, `rayman`

## Debug

```bash
RAYMAN_DEBUG=1 bash ./.Rayman/init.sh
```

## Gate 治理

- `release` profile 默认启用严格门禁：`workspace_hygiene`、`.Rayman/.dist` 同步、`update_from_prompt` 契约测试、签名校验。
- 所有绕过开关都要求同时提供 `RAYMAN_BYPASS_REASON`，并写入 `.Rayman/runtime/decision.log`。
- 常见绕过开关（仅紧急场景使用）：
  - `RAYMAN_ALLOW_NO_GIT=1`
  - `RAYMAN_ALLOW_MISSING_BASE_REF=1`
  - `RAYMAN_ALLOW_DIST_DRIFT=1`
  - `RAYMAN_ALLOW_UNSIGNED_RELEASE=1`
  - `RAYMAN_ALLOW_SIGNATURE_FAIL=1`
- 签名信任链（verify-only）：
  - 公钥：`.Rayman/release/public_key.pem`
  - 公钥指纹：`.Rayman/release/public_key.sha256`
  - 发布说明：`.Rayman/release/SIGNING.md`（包含当前 fingerprint）
  - 私钥必须离线保管，不得入库。
- 可选遥测门禁（默认关闭）：
  - `RAYMAN_RELEASE_METRICS_GUARD=1` 启用 release 的分阶段遥测门禁
  - `RAYMAN_RELEASE_WARN_FAIL_RATE=10`、`RAYMAN_RELEASE_WARN_AVG_MS=8000`（告警阈值，不阻断）
  - `RAYMAN_RELEASE_BLOCK_FAIL_RATE=20`、`RAYMAN_RELEASE_BLOCK_AVG_MS=12000`（阻断阈值）
  - 兼容旧变量：`RAYMAN_RELEASE_MAX_FAIL_RATE` / `RAYMAN_RELEASE_MAX_AVG_MS`（作为 BLOCK 阈值）
  - `RAYMAN_RELEASE_METRICS_LIMIT=20`（抽样条数）
  - `RAYMAN_RELEASE_BASELINE_GUARD=1` 启用“近期 vs 历史基线”的回归守卫
  - `RAYMAN_RELEASE_BASELINE_RECENT_DAYS=3`、`RAYMAN_RELEASE_BASELINE_DAYS=14`、`RAYMAN_RELEASE_BASELINE_MIN_DAYS=3`
  - `RAYMAN_RELEASE_BASELINE_WARN_FAIL_RATE_DELTA=2`、`RAYMAN_RELEASE_BASELINE_WARN_AVG_MS_DELTA=2000`
  - `RAYMAN_RELEASE_BASELINE_BLOCK_FAIL_RATE_DELTA=5`、`RAYMAN_RELEASE_BASELINE_BLOCK_AVG_MS_DELTA=5000`

## Windows 执行策略（ExecutionPolicy）

如果你直接运行 `./.Rayman/init.ps1` 遇到“not digitally signed / cannot be loaded”，请改用：

- `./.Rayman/init.cmd`（推荐）
- 或 `./.Rayman/rayman-win.cmd`
- 或手动运行：`powershell -NoProfile -ExecutionPolicy Bypass -File .\.Rayman\init.ps1`

这是 PowerShell 的执行策略限制导致，并非脚本本身错误。

## 声音提醒（Windows）

- `init.cmd / init.ps1` 遇到需要人工介入的节点时会发出提醒音（如 Sandbox 异常、Target 选择）。
- 初始化完成时也会提醒。
- `setup.ps1` 完成时也会提醒；`rayman.ps1` / `rayman` 的交互式成功命令默认也会触发完成提醒（`--json`、CI、输出重定向场景自动静默，避免污染机器输出）。
- 检测到鼠标或键盘输入后会自动停止提醒。
- `init` 会自动启动后台 `alert-watch`。默认按场景使用不同白名单：Sandbox 窗口优先匹配启动失败/超时/确认类短语；普通 VS Code 窗口（若显式开启监控）只匹配 Target 选择/应用更改/人工确认类短语，避免频繁误报。
- `attention-watch` 还会对同类窗口做标题归一化与聚合：短时间内多个相似窗口只提醒一次，并在提醒文案里汇总数量与样例标题。
- `attention-watch` 会再按高/中/低优先级分层：Sandbox 启动失败/超时/错误码类窗口会用更醒目的高优先级标题；Target 选择/应用更改类窗口走中优先级；普通确认类窗口走低优先级。

环境变量：

- `RAYMAN_ALERTS_ENABLED=0`：关闭全部提醒
- `RAYMAN_ALERT_MANUAL_ENABLED=0`：关闭人工介入提醒
- `RAYMAN_ALERT_DONE_ENABLED=0`：关闭完成提醒
- `RAYMAN_ALERT_TTS_ENABLED=0`：关闭语音播报（默认开启，人工介入/错误会播报）
- `RAYMAN_ALERT_TTS_DONE_ENABLED=0`：关闭“完成提醒”语音播报（默认开启）
- `RAYMAN_ALERT_WATCH_FAIL_MAX_SECONDS=<秒>`：`win-watch.ps1` 失败提醒持续时长（默认 180）
- `RAYMAN_ALERT_WATCH_ENABLED=0`：关闭 `init` 自动启动的后台窗口监控
- `RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED=0`：关闭“每次 prompt 同步时自动确保 attention-watch 在跑”
- `RAYMAN_ALERT_WINDOW_KEYWORDS=a,b,c`：覆盖默认强提示短语白名单（仅建议在你确实知道要监控哪些窗口标题时使用）
- `RAYMAN_ALERT_WINDOW_SANDBOX_KEYWORDS=a,b,c`：仅覆盖 Sandbox 窗口白名单
- `RAYMAN_ALERT_WINDOW_VSCODE_KEYWORDS=a,b,c`：仅覆盖普通 VS Code/其他窗口白名单

## Windows 排障入口（优先看这些）

| 场景 | 入口文件 |
| --- | --- |
| setup 全流程日志 | `.Rayman/logs/setup.win.<timestamp>.log` |
| Playwright 汇总状态（必须先看） | `.Rayman/runtime/playwright.ready.windows.json` |
| Playwright 详细失败日志 | `.Rayman/logs/playwright.ready.win.<timestamp>.log` |
| .NET 执行策略汇总（Windows/WSL 选择结果；fresh copy 会由 workspace guard 刷新/清理；可选包含 owned root pid / cleanup 结果） | `.Rayman/runtime/dotnet.exec.last.json` |
| .NET 执行详细日志（桥接失败/回退原因） | `.Rayman/logs/dotnet.exec.<timestamp>.log` |
| Windows Sandbox bootstrap 日志 | `.Rayman/runtime/windows-sandbox/status/bootstrap.log` |
| MCP 配置与 sqlite 路径 | `.Rayman/mcp/mcp_servers.json` |

## 诊断残影 / 缓存误报识别

当 VS Code Problems 面板里的 PowerShell 提示与当前源码文本**明显对不上**时，优先按下面顺序判断，而不是立刻继续改脚本：

1. **先看源文件是否能通过语法解析**

   - 若源文件 `read + [scriptblock]::Create(...)` 能通过，通常说明不是当前文本级语法错误。

2. **再对比 `.Rayman` 源文件与 `.Rayman/.dist` 镜像文本**

   - 如果当前文本里旧函数名已经消失，但 Problems 仍报旧名字，通常是语言服务残影。

3. **最后排查生成物/历史快照是否在“回声”**

   - 常见噪音源：`.Rayman/state/auto_save.patch`、`.Rayman/runtime/**`、第三方运行时脚本。

默认工作区设置已经做了以下降噪处理：

- `search.exclude`：忽略 `.Rayman/state` 与 `.Rayman/runtime`
- `files.watcherExclude`：忽略 `.Rayman/state/**` 与 `.Rayman/runtime/**`
- `files.exclude`：在资源管理器中隐藏 `.Rayman/state` 与 `.Rayman/runtime`

注意：

- **不会默认隐藏 `.Rayman/.dist`**，因为它仍然是需要校验同步的有效镜像。
- 若 Problems 只在 `.dist` 中报旧名字、而源文件已 clean，优先按“缓存/残影”处理，不建议为追杀假警报继续大改主流程脚本。
- 如需做正式确认，推荐执行：`rayman diagnostics-residual` 或 `rayman release-gate --Mode project --IncludeResidualDiagnostics`。

### Problems 分级速查表

| 看到的现象 | 优先判定 | 建议动作 |
| --- | --- | --- |
| 源文件解析失败，且当前文本能直接对上报错位置 | 真实问题 | 直接修源码 |
| 源文件无错，但 `.dist` 还报旧函数名 / 旧参数名 | 高疑似缓存残影 | 先刷新语言服务，再决定是否处理 |
| 搜索还能在 `.Rayman/state/auto_save.patch` 里命中旧名字 | 历史快照噪音 | 忽略，不作为当前源码判断依据 |
| 运行时目录脚本里出现 `$args` / 第三方包装器 | 运行时产物噪音 | 忽略，不纳入治理脚本修复范围 |
| `rayman diagnostics-residual` 报 source/dist 真漂移 | 真实问题 | 同步 source 与 `.dist` |

## Windows Sandbox 常见问题

- 手工关闭 Sandbox 有影响吗？
  - 有影响。当前这次 sandbox 分支会判定失败（常见为 `exited_before_ready`）。
- 需要等系统自动关闭吗？
  - 不需要。`RAYMAN_SANDBOX_AUTO_CLOSE` 是脚本 `finally` 的收尾行为，不是你要手工等待的步骤。
- 为什么默认会优先走 wsl？
  - 默认 `RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl`；若 WSL 路径失败，setup 会自动回退 `scope=host` 以优先保证初始化完成。
- 如何强制严格 sandbox？
  - 显式设置 `RAYMAN_PLAYWRIGHT_SETUP_SCOPE=sandbox` 后再执行 setup；该模式失败会阻断，不做自动降级。

## VS Code 打开自动启动 Rayman（Windows）

- 运行一次 `init.cmd` 后，Rayman 会自动写入 `.vscode/tasks.json` + `.vscode/settings.json`。
- 之后每次你用 VS Code 打开该 solution/workspace，默认只会触发一个自动任务：
- `Rayman: Folder Open Bootstrap`
- 默认 profile=`conservative`：只同步必跑 watcher/session 去重与 pending task；`daily health`、`context refresh`、轻量依赖检查改为 stale-only。
- runtime 报告：`.Rayman/runtime/vscode_bootstrap.last.json`
- 可选 profile：`RAYMAN_VSCODE_BOOTSTRAP_PROFILE=conservative|active|strict`
- 原来的 `Rayman: Auto Start Watchers`、`Rayman: Check Pending Task`、`Rayman: Daily Health Check`、`Rayman: Check Win Deps`、`Rayman: Check WSL Deps` 仍保留，但改为手动任务，不再在 folderOpen 时并发触发。
- Rayman 只负责清理自己启动的 watcher / bootstrap / 依赖检查残留进程；VS Code 扩展自身的 `wsl.exe ... codex app-server` 不属于 Rayman 清理范围。

环境变量：

- `RAYMAN_VSCODE_AUTO_START_INSTALL_ENABLED=0`：禁用 `init` 自动写入 VS Code 自动任务
- `RAYMAN_VSCODE_FOLDER_OPEN_BOOTSTRAP_ENABLED=0`：禁用 `Rayman: Folder Open Bootstrap`
- `RAYMAN_VSCODE_BOOTSTRAP_PROFILE=conservative|active|strict`：控制 folderOpen 默认行为；默认 `conservative`
- `RAYMAN_AUTO_START_PROMPT_WATCH_ENABLED=0`：自动启动时不拉起 prompt-watch
- `RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED=1`：如确实需要，再显式开启对普通 VS Code 窗口的监控

## Prompt → Requirements 自动同步（可选）

Rayman 会从 prompt 中识别“功能/需求”和“验收标准”，并写入对应的 `*.requirements.md`。

如果你希望**在编辑 prompt 时自动同步**（无需反复跑 init），可以启用 watch：

### Windows

在 PowerShell 里运行：

```powershell
./.Rayman/win-watch.ps1
```

### WSL

```bash
bash ./.Rayman/run/watch.sh
```

### Unified CLI

- WSL: `./.Rayman/rayman <cmd>`
- Windows: `.\.Rayman\rayman.cmd <cmd>`

默认监听：

- `.Rayman/codex_fix_prompt.txt`
- `.Rayman/context/prompt.inbox.md`

---

## 统一 CLI + 自动 fast-init

### 推荐入口

- WSL：`./.Rayman/rayman <command>`
- Windows：`.\.Rayman\rayman.cmd <command>`

常用：

<!-- RAYMAN:COMMANDS:BEGIN -->
### 命令总览（generated）

- 平台标签：`[all]` 跨 bash/PowerShell；`[pwsh-only]` 通过 `rayman.ps1` 委派；`[windows-only]` 需要 Windows Host。

#### Core
- `[ all ]` `rayman help`：Show CLI help and platform tags.
- `[ all ]` `rayman init`：Run full init (environment setup).
- `[ all ]` `rayman watch`：Start watcher (prompt sync + fast-init).
- `[ windows-only ]` `rayman watch-auto`：Start background watchers (prompt-watch + attention-watch).
- `[ windows-only ]` `rayman watch-stop`：Stop background watchers and Rayman-owned workspace helper/test processes.
- `[ windows-only ]` `rayman alert-watch`：Start the foreground attention watcher.
- `[ windows-only ]` `rayman alert-stop`：Stop the background attention watcher.
- `[ all ]` `rayman fast-init`：Generate missing requirements only (no installs).
- `[ all ]` `rayman migrate`：Migrate legacy requirements into the standard layout.
- `[ pwsh-only ]` `rayman migrate-rag`：Migrate legacy RAG data into .rag/<namespace>.
- `[ pwsh-only ]` `rayman rag-bootstrap`：Probe and prepare the RAG Python runtime.
- `[ pwsh-only ]` `rayman ensure-wsl-deps`：Install or verify WSL-side dependencies.
- `[ windows-only ]` `rayman ensure-win-deps`：Check Windows-side dependencies.
- `[ pwsh-only ]` `rayman menu`：Show the interactive command picker.
#### Watchers
- `[ windows-only ]` `rayman watch-auto`：Start background watchers (prompt-watch + attention-watch).
- `[ windows-only ]` `rayman watch-stop`：Stop background watchers and Rayman-owned workspace helper/test processes.
- `[ windows-only ]` `rayman alert-watch`：Start the foreground attention watcher.
- `[ windows-only ]` `rayman alert-stop`：Stop the background attention watcher.
#### Diagnostics
- `[ all ]` `rayman doctor`：Run read-only health checks.
- `[ all ]` `rayman copy-self-check`：Run copy-initialization smoke verification.
- `[ all ]` `rayman check`：Run the baseline check suite.
- `[ pwsh-only ]` `rayman agent-contract`：Check agent assets, instructions, and generated-context contracts.
- `[ all ]` `rayman clean`：Clean runtime, temp, and copy-smoke artifacts.
- `[ all ]` `rayman snapshot`：Create a rollback snapshot under .Rayman/runtime/snapshots.
- `[ all ]` `rayman metrics`：Show telemetry metrics and assertions.
- `[ all ]` `rayman trend`：Generate the daily telemetry trend report.
- `[ all ]` `rayman baseline-guard`：Compare recent telemetry against the historical baseline.
- `[ all ]` `rayman telemetry-export`：Export a telemetry artifact bundle.
- `[ all ]` `rayman telemetry-index`：Rebuild the telemetry artifact index.
- `[ all ]` `rayman telemetry-prune`：Prune telemetry history and refresh the index.
- `[ pwsh-only ]` `rayman diagnostics-residual`：Check residual source/dist diagnostics drift.
- `[ pwsh-only ]` `rayman context-update`：Regenerate local context and auto-skill artifacts.
- `[ pwsh-only ]` `rayman health-check`：Run the daily health check once.
- `[ pwsh-only ]` `rayman proxy-health`：Show the resolved proxy snapshot and sources.
- `[ pwsh-only ]` `rayman single-repo-kpi`：Generate the single-repo KPI dashboard.
#### Automation
- `[ all ]` `rayman ensure-test-deps`：Detect and install project test dependencies.
- `[ all ]` `rayman ensure-playwright`：Prepare Playwright browser automation dependencies.
- `[ windows-only ]` `rayman ensure-winapp`：Check Windows desktop UI Automation readiness.
- `[ pwsh-only ]` `rayman pwa-test`：Run the Playwright PWA flow with local fallback.
- `[ windows-only ]` `rayman winapp-test`：Run the Windows desktop UI flow.
- `[ windows-only ]` `rayman winapp-inspect`：Export the Windows control tree for flow authoring.
- `[ pwsh-only ]` `rayman linux-test`：Run Linux tests in WSL with dependency bootstrap.
- `[ all ]` `rayman dispatch`：Route a task to codex, copilot, or local backends.
- `[ pwsh-only ]` `rayman agent-capabilities`：Sync or inspect Rayman-managed Codex capabilities.
- `[ pwsh-only ]` `rayman review-loop`：Run the dispatch plus test-fix review loop.
- `[ pwsh-only ]` `rayman first-pass-report`：Generate the first-pass KPI report.
- `[ pwsh-only ]` `rayman prompts`：List, show, or apply reusable prompt templates.
- `[ pwsh-only ]` `rayman test-fix`：Run tests/builds and record repair diagnostics.
#### Project Gates
- `[ all ]` `rayman fast-gate`：Run the standard project fast gate.
- `[ all ]` `rayman browser-gate`：Run the standard project browser gate.
- `[ all ]` `rayman full-gate`：Run the standard project full gate.
- `[ pwsh-only ]` `rayman req-ts-backfill`：Backfill requirements timestamps.
#### Release
- `[ pwsh-only ]` `rayman release-gate`：Run release readiness checks and reports.
- `[ all ]` `rayman release`：Run the release profile gate.
- `[ pwsh-only ]` `rayman package-dist`：Build the distributable .Rayman package.
- `[ pwsh-only ]` `rayman deploy`：Run project deployment automation.
- `[ pwsh-only ]` `rayman dist-sync`：Sync and validate the .Rayman/.dist mirror.
- `[ pwsh-only ]` `rayman single-repo-upgrade`：Run the single-repo deep upgrade flow.
#### State
- `[ pwsh-only ]` `rayman cache-clear`：Clear project caches and temporary outputs.
- `[ pwsh-only ]` `rayman state-save`：Save task state and stash changes.
- `[ pwsh-only ]` `rayman state-resume`：Resume task state and restore stashed changes.
<!-- RAYMAN:COMMANDS:END -->

### 审批模式（full-auto）

Rayman 默认启用 `-a full-auto`（Windows/WSL 一致）：Codex/Copilot 的变更无需二次确认，但应先做好分支/提交备份，并在输出中提供验证与回滚步骤。

### AGENTS 文件规范

- canonical 文件名为 `AGENTS.md`。
- 为兼容历史仓库，Rayman 仍可读取 `agents.md`。
- 若两者同时存在且内容不一致，Rayman 会 fail-fast 报错，避免治理规则歧义。

### 新增环境变量

- `RAYMAN_DECISION_LOG_MAX_LINES`（默认 `2000`）：`decision.log` 超过该行数触发轮转。
- `RAYMAN_DECISION_LOG_KEEP_FILES`（默认 `10`）：保留的 `decision.log.*.bak` 数量。
- `RAYMAN_CLEAN_KEEP_DAYS`（默认 `14`）：`rayman clean` 清理阈值天数。
- `RAYMAN_CLEAN_DRY_RUN`（默认 `1`）：`rayman clean` 是否仅预览。
- `RAYMAN_CLEAN_AGGRESSIVE`（默认 `0`）：`rayman clean` 是否额外清理 `.Rayman_full_for_copy`/`Rayman_full_bundle`。
- `RAYMAN_CLEAN_COPY_SMOKE_ARTIFACTS`（默认 `0`）：`rayman clean` 是否额外清理系统临时目录下 `rayman_copy_smoke_*` 产物。
- `RAYMAN_AUTO_SNAPSHOT_ON_NO_GIT`（默认 `1`）：非 Git 仓库高风险命令前自动快照开关。
- `RAYMAN_SNAPSHOT_KEEP`（默认 `5`）：快照保留数量。
- `RAYMAN_AUTO_INSTALL_TEST_DEPS`（默认 `1`）：`test-fix` / `ensure-test-deps` 前自动安装缺失测试依赖；MAUI 项目会额外执行 `dotnet workload restore <project.csproj>`。
- `RAYMAN_REQUIRE_TEST_DEPS`（默认 `1`）：测试依赖仍缺失时是否阻断测试流程。
- `RAYMAN_SETUP_GIT_INIT`（默认 `1`）：`setup` 时自动初始化本地 Git 仓库；关闭后会保留原有 `AllowNoGit` 回退。
- `RAYMAN_SETUP_GITHUB_LOGIN`（默认 `1`）：交互式 `setup` 时尝试执行 GitHub 登录与 `auth setup-git`。
- `RAYMAN_SETUP_GITHUB_LOGIN_STRICT`（默认 `0`）：开启后，GitHub 登录 / `auth setup-git` 失败会阻断 `setup`。
- `RAYMAN_GITHUB_HOST`（默认 `github.com`）：`setup` 使用的 GitHub host。
- `RAYMAN_GITHUB_GIT_PROTOCOL`（默认 `https`）：`setup` 登录时使用的 Git 协议。
- `RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL`（默认 `1`）：`test-fix` 重试阶段是否执行常见依赖修复动作（如 dotnet restore / dotnet workload restore / npm ci 等）。
- `RAYMAN_USE_SANDBOX`（默认 `0`）：`test-fix` 默认在本机执行；设置为 `1` 可恢复 Docker sandbox 执行路径。
- `RAYMAN_DOTNET_CHANNEL`（默认 `LTS`）：当工作区无法从 `global.json` 或目标框架解析 SDK 主版本时，作为 dotnet-install 的回退 channel（Windows/WSL）。
- `RAYMAN_DOTNET_WINDOWS_PREFERRED`（默认 `1`）：`test-fix` 的 `.NET` 命令在 WSL 下优先走 Windows Host 执行链路。
- `RAYMAN_DOTNET_WINDOWS_STRICT`（默认 `0`）：Windows 执行失败时是否禁止回退 WSL（`1`=严格失败，`0`=自动回退）。
- `RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS`（默认 `1800`）：Windows Host 执行 `.NET` 命令超时（秒）。
- `RAYMAN_PLAYWRIGHT_REQUIRE`（默认 `1`）：初始化时 Playwright 未就绪是否阻断。
- `RAYMAN_PLAYWRIGHT_BROWSER`（默认 `chromium`）：初始化准备的 Playwright 浏览器。
- `RAYMAN_PLAYWRIGHT_SETUP_SCOPE`（默认 `wsl`）：setup 中 Playwright 准备范围（`wsl|host|all|sandbox`）。
- `RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS`（默认 `1800`）：Playwright/Sandbox 就绪等待超时（秒）。
- `RAYMAN_PLAYWRIGHT_AUTO_INSTALL`（默认 `1`）：setup 时是否先自动安装 Playwright 运行时（用于 Copilot/Codex 网页自动化调试）。
- `RAYMAN_MCP_SQLITE_DB_PATH`（默认空）：显式指定 sqlite MCP 的 `--db-path`（优先级最高，仅影响本次进程）。
- `RAYMAN_MCP_SQLITE_DB_AUTOFIX`（默认 `1`）：是否将旧工作区遗留的 sqlite 绝对路径自动修复到当前工作区。
- `RAYMAN_AGENT_DEFAULT_BACKEND`（默认 `local`）：`dispatch` 默认后端。
- `RAYMAN_AGENT_FALLBACK_ORDER`（默认 `codex,local`）：`dispatch` 后端降级顺序。
- `RAYMAN_AGENT_CLOUD_WHITELIST`（默认空）：允许云端委派的仓库白名单（逗号分隔，支持 `*`）。
- `RAYMAN_AGENT_CLOUD_ENABLED`（默认 `0`）：是否开启云端后端（仍需白名单命中）。
- `RAYMAN_AGENT_POLICY_BYPASS`（默认 `0`）：是否请求绕过 `dispatch` 的 pre-dispatch policy（需同时提供 `RAYMAN_BYPASS_REASON`）。
- `RAYMAN_AGENT_CAPABILITIES_ENABLED`（默认 `1`）：总开关；关闭后不再写入 Rayman managed `.codex/config.toml` block。
- `RAYMAN_AGENT_CAP_OPENAI_DOCS_ENABLED`（默认 `1`）：控制 `openai_docs` capability。
- `RAYMAN_AGENT_CAP_WEB_AUTO_TEST_ENABLED`（默认 `1`）：控制 `web_auto_test` capability；开启时 `sync` 会先执行 `rayman ensure-playwright`。
- `RAYMAN_AGENT_CAP_WINAPP_AUTO_TEST_ENABLED`（默认 `1`）：控制 `winapp_auto_test` capability；仅在 Windows 交互式桌面会话下激活。
- `RAYMAN_WINAPP_REQUIRE`（默认 `0`）：`ensure-winapp` / `winapp-test` 在桌面能力未就绪时是否阻断。
- `RAYMAN_WINAPP_DEFAULT_TIMEOUT_MS`（默认 `15000`）：Windows 桌面 flow 默认超时。
- `RAYMAN_SYSTEM_SLIM_ENABLED`（默认 `1`）：系统能力精简总开关（`0`=禁用系统委派，回到 Rayman 原路由）。
- `RAYMAN_SYSTEM_SLIM_NOTIFY_ON_UPGRADE`（默认 `1`）：VSCode/Codex 升级时是否在 `setup/init` 提醒继续精简。
- `RAYMAN_FIRST_PASS_WINDOW`（默认 `20`）：`first-pass-report` 默认统计窗口。
- `RAYMAN_REVIEW_LOOP_MAX_ROUNDS`（默认 `2`）：`review-loop` 最大轮数。
- `RAYMAN_SCM_IGNORE_MODE`（默认：external=`gitignore`，source=`info-exclude`）：SCM 忽略规则注入目标（`info-exclude|gitignore|off`）。
- `RAYMAN_SCM_CHANGE_SOFT_LIMIT`（默认 `100`）：setup 末尾 SCM 可见变更总数的软告警阈值。
- `RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS`（默认 `0`）：控制当前工作区是否显式放行 Rayman 管理资产 / 本地生成资产的 Git 跟踪；默认阻断，仅在你明确需要临时入库时手工设置为 `1`。

说明：默认是“自动补全并阻断失败”。如需临时关闭，可显式设置对应变量为 `0`（例如 `RAYMAN_AUTO_INSTALL_TEST_DEPS=0`）。

## Agent Capabilities

- Rayman 继续把 `.Rayman/mcp/mcp_servers.json` 留给自身 runtime MCP，例如 `sqlite`；Codex 专用能力改由工作区级 `.codex/config.toml` 管理。
- 当前内置 capability registry 位于 `.Rayman/config/agent_capabilities.json`，默认提供：
  - `openai_docs`：为 Codex 注入官方 OpenAI Docs MCP（`openaiDeveloperDocs`）。
  - `web_auto_test`：为 Codex 注入 Playwright MCP（`playwright`），并保留 `rayman ensure-playwright` / `rayman pwa-test` 作为降级链路。
  - `winapp_auto_test`：为 Codex 注入 Rayman 本地 Windows 桌面 MCP（`raymanWinApp`），并保留 `rayman ensure-winapp` / `rayman winapp-test` 作为降级链路。
- `setup/init` 会自动同步 capability；你也可以手动运行 `rayman agent-capabilities --sync`。状态报告位于 `.Rayman/runtime/agent_capabilities.report.md`。
- Copilot 不做等价 MCP 注入；它共享 instructions、任务入口和 Rayman fallback 命令。
- `web_auto_test` 负责网页自动化；`winapp_auto_test` 负责 Windows 桌面自动化。MAUI 在 v1 仅指 Windows 桌面 target，不包含 Android/iOS/macOS。

## 打包与拷贝净化策略

- `rayman package-dist` 默认剔除 `runtime/logs`，减少旧环境噪声。
- 若使用 `-IncludeRuntimeFiles` 或 `-IncludeLogs`，默认仍会净化历史产物；如需保留历史，可加：
  - `-KeepRuntimeHistory`
  - `-KeepLogHistory`
- `rayman doctor --copy-smoke` 在临时复制目录中默认会净化 `runtime/logs` 后再执行 setup。
