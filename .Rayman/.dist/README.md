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

- 本地 `run_fast_contract.sh` 在缺少 `${RAYMAN_BASE_REF:-origin/main}` 时，会自动按 `missing-base-ref` 写入一次 bypass 决策并继续；CI 与直接运行 `validate_requirements.sh` 仍保持严格，不走这个默认 bypass。

依赖说明：

- JSON contract 校验依赖 `python + jsonschema`
- Bash 逻辑单测依赖 `bats-core`
- PowerShell 逻辑单测依赖 `Pester 5`

CI 约定：

- PR / push 走 hosted matrix：`ubuntu-latest` + `windows-latest`
- nightly / manual 额外跑深度 smoke
- self-hosted 深度 smoke 约定 runner labels：`self-hosted`, `windows`, `rayman`

## 功能账本与 2026 增强路线图

- `.Rayman/release/FEATURE_INVENTORY.md`：当前 tracked 功能面账本，按入口与 setup、watch/alerts、agent/capability、browser/winapp、release/CI/security、state/transfer/docs/telemetry 分层。
- `.Rayman/release/ENHANCEMENT_ROADMAP_2026.md`：基于官方平台资料整理的 P0 / P1 / P2 增强路线图。
- `.github/model-policy.md`：hosted model selection 与平台能力边界说明；仅做文档与检测，不改变本仓库默认 CLI 语义。
- 这 3 份文档会被纳入 source / `.dist` / agent contract 的同步面，避免“审查建议只存在于聊天记录里”。

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
- 默认提醒面为 `log-first`：人工介入/错误优先写终端与 `.Rayman/runtime/attention.last.json`；不再默认发 Windows toast、语音或命令完成提醒。
- `setup.ps1` 完成和 `rayman.ps1` / `rayman` 的交互式成功命令仍会走统一提醒链路，但默认因 `RAYMAN_ALERT_DONE_ENABLED=0` 保持静默。
- `init` 与 VS Code folder-open 默认不再单独拉起后台 `alert-watch`；需要时可显式开启嵌入到共享 `win-watch.ps1` 的 attention scan，或手动运行 `rayman.ps1 alert-watch`。
- `attention-watch` 还会对同类窗口做标题归一化与聚合：短时间内多个相似窗口只提醒一次，并在提醒文案里汇总数量与样例标题。
- `attention-watch` 会再按高/中/低优先级分层：Sandbox 启动失败/超时/错误码类窗口会用更醒目的高优先级标题；Target 选择/应用更改类窗口走中优先级；普通确认类窗口走低优先级。

环境变量：

- `RAYMAN_ALERTS_ENABLED=0`：关闭全部提醒
- `RAYMAN_ALERT_MANUAL_ENABLED=0`：关闭人工介入提醒
- `RAYMAN_ALERT_SURFACE=log|toast|silent`：控制提醒落点；默认 `log`
- `RAYMAN_ALERT_DONE_ENABLED=0`：关闭完成提醒（默认关闭）
- `RAYMAN_ALERT_TTS_ENABLED=0`：关闭语音播报（默认关闭）
- `RAYMAN_ALERT_TTS_DONE_ENABLED=0`：关闭“完成提醒”语音播报（默认关闭）
- `RAYMAN_ALERT_WATCH_FAIL_MAX_SECONDS=<秒>`：`win-watch.ps1` 失败提醒持续时长（默认 180）
- `RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED=0`：在共享 `win-watch.ps1` 内启用 attention scan（默认关闭）
- `RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED=0`：关闭 prompt sync 场景下的额外 attention 自启钩子（默认关闭）
- `RAYMAN_AUTO_SAVE_WATCH_ENABLED=0`：在共享 `win-watch.ps1` 内启用 auto-save（默认关闭）
- `RAYMAN_ALERT_WINDOW_KEYWORDS=a,b,c`：覆盖默认强提示短语白名单（仅建议在你确实知道要监控哪些窗口标题时使用）
- `RAYMAN_ALERT_WINDOW_SANDBOX_KEYWORDS=a,b,c`：仅覆盖 Sandbox 窗口白名单
- `RAYMAN_ALERT_WINDOW_VSCODE_KEYWORDS=a,b,c`：仅覆盖普通 VS Code/其他窗口白名单

恢复旧行为（显式 opt-in）：

- `RAYMAN_ALERT_SURFACE=toast`
- `RAYMAN_ALERT_DONE_ENABLED=1`
- `RAYMAN_ALERT_TTS_ENABLED=1`
- `RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED=1`
- `RAYMAN_AUTO_SAVE_WATCH_ENABLED=1`

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
- `Rayman: Stop Watchers` 会显式传 `-IncludeResidualCleanup -OwnerPid ${env:VSCODE_PID}`，用于清理当前 workspace 的残留 watcher / MCP / exitwatch 进程树。
- Rayman 只负责清理自己启动的 watcher / bootstrap / 依赖检查残留进程；VS Code 扩展自身的 `wsl.exe ... codex app-server` 不属于 Rayman 清理范围。

环境变量：

- `RAYMAN_VSCODE_AUTO_START_INSTALL_ENABLED=0`：禁用 `init` 自动写入 VS Code 自动任务
- `RAYMAN_VSCODE_FOLDER_OPEN_BOOTSTRAP_ENABLED=0`：禁用 `Rayman: Folder Open Bootstrap`
- `RAYMAN_VSCODE_BOOTSTRAP_PROFILE=conservative|active|strict`：控制 folderOpen 默认行为；默认 `conservative`
- `RAYMAN_AUTO_START_PROMPT_WATCH_ENABLED=0`：自动启动时不拉起 prompt-watch
- `RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED=0`：自动启动时在共享 `win-watch.ps1` 内启用 attention scan
- `RAYMAN_AUTO_SAVE_WATCH_ENABLED=0`：自动启动时在共享 `win-watch.ps1` 内启用 auto-save
- `RAYMAN_VSCODE_EXIT_LINKED_STOP_ENABLED=0`：关闭 VS Code owner 退出后按 session 自动回收后台服务
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

- 平台标签：`[all]` 同时支持 `rayman` / `rayman.ps1`；`[pwsh-only]` 与 `[windows-only]` 统一使用 `rayman.ps1`。

#### Core
- `[ all ]` `rayman help`：Show CLI help and platform tags.
- `[ all ]` `rayman init`：Run full init (environment setup).
- `[ all ]` `rayman watch`：Start watcher (prompt sync + fast-init).
#### Watchers
- `[ windows-only ]` `rayman.ps1 watch-auto`：Start background watchers (prompt-watch + attention-watch).
- `[ windows-only ]` `rayman.ps1 watch-stop`：Stop background watchers and helper processes.
- `[ windows-only ]` `rayman.ps1 alert-watch`：Start the foreground attention watcher.
- `[ windows-only ]` `rayman.ps1 alert-stop`：Stop the background attention watcher.
#### Core
- `[ all ]` `rayman fast-init`：Generate missing requirements only (no installs).
- `[ all ]` `rayman migrate`：Migrate legacy requirements into the standard layout.
- `[ pwsh-only ]` `rayman.ps1 migrate-rag`：Migrate legacy RAG data into .rag/<namespace>.
- `[ pwsh-only ]` `rayman.ps1 rag-bootstrap`：Probe and prepare the RAG Python runtime.
#### Diagnostics
- `[ all ]` `rayman doctor`：Run read-only health checks.
- `[ all ]` `rayman copy-self-check`：Run copy-initialization smoke verification.
- `[ pwsh-only ]` `rayman.ps1 self-check`：Alias of `copy-self-check`.
- `[ pwsh-only ]` `rayman.ps1 copy-check`：Alias of `copy-self-check`.
- `[ all ]` `rayman check`：Run the baseline check suite.
#### Automation
- `[ all ]` `rayman ensure-test-deps`：Detect and install project test dependencies.
- `[ all ]` `rayman ensure-playwright`：Prepare Playwright browser automation dependencies.
- `[ windows-only ]` `rayman.ps1 ensure-winapp`：Check Windows desktop UI Automation readiness.
- `[ pwsh-only ]` `rayman.ps1 pwa-test`：Run the Playwright PWA flow with local fallback.
- `[ windows-only ]` `rayman.ps1 winapp-test`：Run the Windows desktop UI flow.
- `[ windows-only ]` `rayman.ps1 winapp-inspect`：Export the Windows control tree for flow authoring.
- `[ pwsh-only ]` `rayman.ps1 linux-test`：Run Linux tests in WSL with dependency bootstrap.
- `[ all ]` `rayman dispatch`：Route a task to codex, copilot, or local backends.
- `[ all ]` `rayman codex`：Manage Rayman-scoped Codex accounts, switching, and CLI execution.
- `[ pwsh-only ]` `rayman.ps1 agent-capabilities`：Sync or inspect Rayman-managed Codex capabilities.
#### Diagnostics
- `[ pwsh-only ]` `rayman.ps1 agent-contract`：Check agent assets, instructions, and generated-context contracts.
#### Automation
- `[ pwsh-only ]` `rayman.ps1 review-loop`：Run the dispatch plus test-fix review loop.
- `[ pwsh-only ]` `rayman.ps1 first-pass-report`：Generate the first-pass KPI report.
- `[ pwsh-only ]` `rayman.ps1 prompts`：List, show, or apply reusable prompt templates.
#### Project Gates
- `[ all ]` `rayman fast-gate`：Run the standard project fast gate.
- `[ all ]` `rayman browser-gate`：Run the standard project browser gate.
- `[ all ]` `rayman full-gate`：Run the standard project full gate.
#### Release
- `[ pwsh-only ]` `rayman.ps1 release-gate`：Run release readiness checks and reports.
- `[ all ]` `rayman release`：Run the release profile gate.
- `[ pwsh-only ]` `rayman.ps1 version`：Show managed version state and consistency.
- `[ pwsh-only ]` `rayman.ps1 newversion`：Set the managed Rayman version across governed files.
- `[ pwsh-only ]` `rayman.ps1 package-dist`：Build the distributable .Rayman package.
- `[ pwsh-only ]` `rayman.ps1 package`：Alias of `package-dist`.
#### Diagnostics
- `[ all ]` `rayman clean`：Clean runtime, temp, and copy-smoke artifacts.
- `[ all ]` `rayman snapshot`：Create a rollback snapshot under .Rayman/runtime/snapshots.
- `[ all ]` `rayman metrics`：Show telemetry metrics and assertions.
- `[ all ]` `rayman trend`：Generate the daily telemetry trend report.
- `[ all ]` `rayman baseline-guard`：Compare recent telemetry against the historical baseline.
- `[ all ]` `rayman telemetry-export`：Export a telemetry artifact bundle.
- `[ all ]` `rayman telemetry-index`：Rebuild the telemetry artifact index.
- `[ all ]` `rayman telemetry-prune`：Prune telemetry history and refresh the index.
#### Release
- `[ pwsh-only ]` `rayman.ps1 deploy`：Run project deployment automation.
#### State
- `[ pwsh-only ]` `rayman.ps1 cache-clear`：Clear project caches and temporary outputs.
- `[ pwsh-only ]` `rayman.ps1 state-save`：Save task state and stash changes.
- `[ pwsh-only ]` `rayman.ps1 state-resume`：Resume task state and restore stashed changes.
#### Automation
- `[ pwsh-only ]` `rayman.ps1 test-fix`：Run tests/builds and record repair diagnostics.
#### Project Gates
- `[ pwsh-only ]` `rayman.ps1 req-ts-backfill`：Backfill requirements timestamps.
#### Release
- `[ pwsh-only ]` `rayman.ps1 dist-sync`：Sync and validate the .Rayman/.dist mirror.
#### Diagnostics
- `[ pwsh-only ]` `rayman.ps1 diagnostics-residual`：Check residual source/dist diagnostics drift.
- `[ pwsh-only ]` `rayman.ps1 context-update`：Regenerate local context and auto-skill artifacts.
- `[ pwsh-only ]` `rayman.ps1 health-check`：Run the daily health check once.
- `[ pwsh-only ]` `rayman.ps1 one-click-health`：Force daily health check and refresh proxy health snapshot.
- `[ pwsh-only ]` `rayman.ps1 health`：Alias of `one-click-health`.
- `[ pwsh-only ]` `rayman.ps1 一键健康检查`：Alias of `one-click-health`.
- `[ pwsh-only ]` `rayman.ps1 proxy-health`：Show the resolved proxy snapshot and sources.
- `[ pwsh-only ]` `rayman.ps1 proxy-check`：Alias of `proxy-health`.
#### Core
- `[ pwsh-only ]` `rayman.ps1 ensure-wsl-deps`：Install or verify WSL-side dependencies.
- `[ windows-only ]` `rayman.ps1 ensure-win-deps`：Check Windows-side dependencies.
#### Release
- `[ pwsh-only ]` `rayman.ps1 single-repo-upgrade`：Run the single-repo deep upgrade flow.
#### Diagnostics
- `[ pwsh-only ]` `rayman.ps1 single-repo-kpi`：Generate the single-repo KPI dashboard.
#### Core
- `[ pwsh-only ]` `rayman.ps1 menu`：Show the interactive command picker.
- `[ pwsh-only ]` `rayman.ps1 interactive`：Alias of menu.
#### State
- `[ all ]` `rayman transfer-export`：[Agent/Handover] 导出当前工作区及系统状态信息。
- `[ all ]` `rayman transfer-import`：[Agent/Handover] 导入并恢复外部环境及工作区状态信息。
<!-- RAYMAN:COMMANDS:END -->

### Rayman Codex alias 与 profile 术语

- 交互式终端里直接运行 `rayman.ps1 codex`，或在 `rayman.ps1 menu` 里选择 `codex`，都会进入带说明的 Codex 二级菜单。
- Codex 二级菜单会显示当前 workspace、当前绑定 alias、认证状态、VS Code user profile 和当前有效的 Codex execution profile。
- `rayman codex menu` 是可显式调用的二级菜单入口；显式动作如 `rayman codex status --json`、`login`、`switch`、`run`、`upgrade` 保持原样。
- `rayman codex login` 现在会从 `%APPDATA%\Code\User\globalStorage\storage.json` 读取当前 workspace 绑定的 **VS Code user profile**。
- 省略 `--alias` 时，Rayman 会先给出一组可选 alias：`main`、已有 alias、推荐第二账号 `gpt-alt`，以及 `custom` 手工输入。
- `rayman codex upgrade` 会查询 npm registry 上 `@openai/codex` 的最新版本，并在当前安装链路属于 npm 全局安装时执行 `npm install -g @openai/codex`。
- `rayman codex login --alias <alias>` 会在 alias 专属 `CODEX_HOME` 下执行 `codex login --device-auth`；登录成功后，会把当前 workspace 的 `[projects."<workspace>"] trust_level = "trusted"` 写回该 alias 的 `config.toml`，而不是手工写 token。
- `rayman codex switch --alias <alias>` 会切换当前 workspace 绑定；如果该 alias 已认证，Rayman 会顺手补齐同一份 workspace trust 配置。
- Codex 二级菜单里的“管理账号”支持：查看 alias 详情、更新默认 Codex execution profile、重新设备码登录、安全删除 alias、彻底删除 alias。
- 安全删除只会移除 Rayman registry 与已知 workspace 引用，不会删掉该 alias 的 `CODEX_HOME`、本地凭据或 `config.toml`；彻底删除会额外删除 `CODEX_HOME`。
- 对全新 alias，`rayman codex status` 遇到缺少本地凭据文件时会归一化为 `not_logged_in`，避免误报成 `probe_failed`。
- `rayman codex status/login/switch/run` 默认都会先检查 npm registry 最新版本；若当前 Codex CLI 落后且安装来源是 npm，全局升级会先执行，再进入后续动作。
- 下面 3 个概念必须分开：
- `VS Code user profile`：左下角“管理 -> 配置文件”里切换的用户配置文件。
- `Rayman bootstrap profile`：`RAYMAN_VSCODE_BOOTSTRAP_PROFILE=conservative|active|strict`，只控制 folder-open bootstrap 行为。
- `Codex execution profile`：`rayman codex ... --profile <name>` 传给 Codex CLI 的执行 profile。
- `rayman codex status --json` 和 `.Rayman/runtime/codex.auth.status.json` 会分别输出 `vscode_user_profile`、`account_alias`、`profile`，避免继续把不同含义都写成裸 `profile`。
- Codex CLI 自动升级策略由 `RAYMAN_CODEX_AUTO_UPDATE_POLICY=latest|compatibility|off` 控制：默认 `latest`，`compatibility` 只在最低兼容线或配置探测失败时升级，`off` 完全关闭自动升级。
- 兼容旧变量 `RAYMAN_CODEX_AUTO_UPDATE_ENABLED`：设为 `0` 时强制等价于 `off`；设为 `1` 时仅表示允许自动升级，若未显式指定 policy，则仍走默认 `latest`。

### 审批模式（full-auto）

Rayman 默认启用 `-a full-auto`（Windows/WSL 一致）：Codex/Copilot 的变更无需二次确认，但应先做好分支/提交备份，并在输出中提供验证与回滚步骤。
在 Windows 上执行审批敏感的 PowerShell 自动化时，优先收敛到 `powershell.exe -Command` / `-File`；`pwsh` 保留给 PowerShell 7 兼容性需求或非 Windows Host 场景。

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
- `RAYMAN_CODEX_AUTO_UPDATE_POLICY`（默认 `latest`）：`rayman codex status/login/switch/run` 调用前如何处理 Codex CLI 自动升级；支持 `latest|compatibility|off`。
- `RAYMAN_CODEX_AUTO_UPDATE_ENABLED`（兼容旧开关，默认未设置）：设为 `0` 时强制关闭 Codex CLI 自动升级；设为 `1` 时仅表示允许自动升级，未指定 policy 时仍按 `latest` 处理。
- Agent 执行隔离由 Codex 内置 sandbox 负责；Rayman 已移除通用测试 sandbox wrapper，不再提供 `RAYMAN_USE_SANDBOX`。
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
- `RAYMAN_AGENT_CAPABILITIES_ENABLED`（默认 `1`）：总开关；关闭后不再写入 Rayman managed `.codex/config.toml` block（MCP 与 multi-agent 都会一起停用）。
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

- Rayman 继续把 `.Rayman/mcp/mcp_servers.json` 留给自身 runtime MCP，例如 `sqlite`；Codex 专用能力改由工作区级 `.codex/config.toml` 管理，而该文件现在同时承载 4 个 Rayman-managed slice：`capabilities`、`project_doc`、`profiles`、`subagents`。
- Codex 内置 sandbox 负责 Agent 执行隔离；本 README 中的 “Windows Sandbox” / `scope=sandbox` 专指 Playwright / PWA UI 基座，不等同于已移除的通用测试 wrapper。
- 当前内置 capability registry 位于 `.Rayman/config/agent_capabilities.json`，默认提供：
  - `openai_docs`：为 Codex 注入官方 OpenAI Docs MCP（`openaiDeveloperDocs`）。
  - `web_auto_test`：为 Codex 注入 Playwright MCP（`playwright`），并保留 `rayman ensure-playwright` / `rayman pwa-test` 作为降级链路。
  - `winapp_auto_test`：为 Codex 注入 Rayman 本地 Windows 桌面 MCP（`raymanWinApp`），并保留 `rayman ensure-winapp` / `rayman winapp-test` 作为降级链路。
- `project_doc` 会显式配置 `project_doc_fallback_filenames = ["agents.md"]`，避免 `AGENTS.md` 缺失或体积变化时丢掉 Rayman 规则。
- 当前内置 Codex profiles 固定为：
  - `rayman_docs`
  - `rayman_review`
  - `rayman_browser`
  - `rayman_winapp`
  - `rayman_fast`
- Rayman 还会同步 multi-agent 默认能力层，角色固定为：
  - `rayman_explorer`：探索、定位入口、收集证据。
  - `rayman_reviewer`：做 correctness / regression / test risk 复核。
  - `rayman_docs_researcher`：只读，优先 OpenAI Docs MCP。
  - `rayman_browser_debugger`：`workspace-write`，优先 Playwright MCP。
  - `rayman_winapp_debugger`：`workspace-write`，优先 Rayman WinApp MCP。
  - `rayman_worker`：边界清晰的补丁、测试、修复侧车。
- `setup/init` 会自动同步 capability 与 multi-agent 配置；你也可以手动运行 `rayman agent-capabilities --sync`。状态报告位于 `.Rayman/runtime/agent_capabilities.report.md`，并会写出 supported/effective/degraded 信息。
- Rayman 还会维护跨 Copilot/Codex 共享的 capability 资产：
  - `.github/agents/*.agent.md`
  - `.github/skills/*/SKILL.md`
  - `.github/prompts/*.prompt.md`
- `dispatch` / `review_loop` 的 `prompt_key` 现在使用真实 prompt 文件名（例如 `review.initial.prompt.md`）作为路由键，避免独立别名继续分叉。
- capability report 还会额外记录 `codex_runtime_host`、`path_normalization_status`、`project_profiles_written`、`subagents_written`、`custom_agents_present`、`skills_present`，并对 Playwright / WinApp 同时保留 host-side 与 effective/runtime-host 状态。
- Codex 只有在任务或 prompt 中被显式要求时才会起 subagent；Rayman 的 `dispatch` / system instructions 会显式点名角色与触发条件。
- 如果 multi-agent 不可用，Rayman 会保留 MCP / 单代理流程，并把降级原因写进 report/context，避免阻断基础工作流。
- Copilot 不做等价 MCP 注入；它共享 instructions、任务入口和 Rayman fallback 命令。
- Copilot Memory、GitHub.com coding-agent 的 model picker / Auto model selection 属于平台能力；Rayman 只做文档和检测，不在仓库内假装已托管。
- hosted model selection 边界与推荐用法见 `.github/model-policy.md`；当前功能盘点与增强优先级见 `.Rayman/release/FEATURE_INVENTORY.md`、`.Rayman/release/ENHANCEMENT_ROADMAP_2026.md`。
- `web_auto_test` 负责网页自动化；`winapp_auto_test` 负责 Windows 桌面自动化。MAUI 在 v1 仅指 Windows 桌面 target，不包含 Android/iOS/macOS。

## 打包与拷贝净化策略

- `rayman package-dist` 默认剔除 `runtime/logs`，减少旧环境噪声。
- 若使用 `-IncludeRuntimeFiles` 或 `-IncludeLogs`，默认仍会净化历史产物；如需保留历史，可加：
  - `-KeepRuntimeHistory`
  - `-KeepLogHistory`
- `rayman doctor --copy-smoke` 在临时复制目录中默认会净化 `runtime/logs` 后再执行 setup。
