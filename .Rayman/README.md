# Rayman v159

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
向量库默认写入工作区根目录 `.rag/<命名空间>/chroma_db`（命名空间默认是工作区名）；若检测到已存在，默认会复用并跳过重建，仅在显式传入 `-ForceReindex` 时重建。
若 `setup` 检测到旧路径 `.Rayman/state/chroma_db` 仍有数据且新路径为空，会自动打印迁移命令提示。
`setup.ps1` 无参数时会默认自动迁移旧向量库到新路径；如需关闭可使用 `-NoAutoMigrateLegacyRag`。

## Doctor（推荐）

```bash
bash ./.Rayman/run/doctor.sh
```

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
- 检测到鼠标或键盘输入后会自动停止提醒。
- `init` 会自动启动后台 `alert-watch`，监控 VS Code / Sandbox 等窗口标题中的“确认/选择/错误/沙盒”等关键词。

环境变量：

- `RAYMAN_ALERTS_ENABLED=0`：关闭全部提醒
- `RAYMAN_ALERT_MANUAL_ENABLED=0`：关闭人工介入提醒
- `RAYMAN_ALERT_DONE_ENABLED=0`：关闭完成提醒
- `RAYMAN_ALERT_TTS_ENABLED=0`：关闭语音播报（默认开启，人工介入/错误会播报）
- `RAYMAN_ALERT_TTS_DONE_ENABLED=0`：关闭“完成提醒”语音播报（默认开启）
- `RAYMAN_ALERT_WATCH_FAIL_MAX_SECONDS=<秒>`：`win-watch.ps1` 失败提醒持续时长（默认 180）
- `RAYMAN_ALERT_WATCH_ENABLED=0`：关闭 `init` 自动启动的后台窗口监控
- `RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED=0`：关闭“每次 prompt 同步时自动确保 attention-watch 在跑”

## Windows 排障入口（优先看这些）

| 场景 | 入口文件 |
| --- | --- |
| setup 全流程日志 | `.Rayman/logs/setup.win.<timestamp>.log` |
| Playwright 汇总状态（必须先看） | `.Rayman/runtime/playwright.ready.windows.json` |
| Playwright 详细失败日志 | `.Rayman/logs/playwright.ready.win.<timestamp>.log` |
| .NET 执行策略汇总（Windows/WSL 选择结果） | `.Rayman/runtime/dotnet.exec.last.json` |
| .NET 执行详细日志（桥接失败/回退原因） | `.Rayman/logs/dotnet.exec.<timestamp>.log` |
| Windows Sandbox bootstrap 日志 | `.Rayman/runtime/windows-sandbox/status/bootstrap.log` |
| MCP 配置与 sqlite 路径 | `.Rayman/mcp/mcp_servers.json` |

## Windows Sandbox 常见问题

- 手工关闭 Sandbox 有影响吗？
  - 有影响。当前这次 sandbox 分支会判定失败（常见为 `exited_before_ready`）。
- 需要等系统自动关闭吗？
  - 不需要。`RAYMAN_SANDBOX_AUTO_CLOSE` 是脚本 `finally` 的收尾行为，不是你要手工等待的步骤。
- 为什么默认会优先走 wsl？
  - 默认 `RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl`；若 WSL 路径失败，setup 会自动回退 `scope=host` 以优先保证初始化完成。
- 如何强制严格 sandbox？
  - 显式设置 `RAYMAN_PLAYWRIGHT_SETUP_SCOPE=sandbox` 后再执行 setup；该模式失败会阻断，不做自动降级。

## VS Code 打开自动拉起 watcher（Windows）

- 运行一次 `init.cmd` 后，Rayman 会自动写入 `.vscode/tasks.json` + `.vscode/settings.json`。
- 之后每次你用 VS Code 打开该 solution/workspace，会自动后台拉起：
  - `prompt-watch`（requirements 同步）
  - `attention-watch`（人工介入弹窗提醒）

环境变量：

- `RAYMAN_VSCODE_AUTO_START_INSTALL_ENABLED=0`：禁用 `init` 自动写入 VS Code 自动任务
- `RAYMAN_AUTO_START_PROMPT_WATCH_ENABLED=0`：自动启动时不拉起 prompt-watch

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

- `rayman init`：完整初始化（安装/准备环境）
- `rayman watch`：监听 prompt 与 .sln/.slnx，自动同步 requirements + 自动补齐新增项目 requirements（fast-init）
- `rayman migrate`：迁移旧版 requirements 到统一结构
- `rayman watch-auto`：后台拉起 prompt-watch + attention-watch
- `rayman watch-stop`：停止后台 prompt-watch + attention-watch
- `rayman alert-watch`：前台运行“人工介入窗口”监控（会响铃提醒）
- `rayman alert-stop`：停止后台提醒监控
- `rayman fast-init`：只补齐 requirements（不安装任何包）
- `rayman check`：执行基础检查链路
- `rayman ensure-test-deps`：检测并自动安装项目测试所需 SDK（dotnet/node/python，按项目类型）
- `rayman ensure-playwright`：检测并安装 Playwright Chromium 自动验收链路（Windows 会同时校验 WSL + Sandbox）
- `rayman dispatch --TaskKind bugfix`：按任务类型路由到 `copilot|codex|local`，并写入 `.Rayman/runtime/agent_runs/*.json`
- `rayman dispatch --PolicyBypass --BypassReason "..."`：仅在紧急场景绕过 pre-dispatch policy（强制审计到 `.Rayman/runtime/decision.log`）
- `rayman review-loop --TaskKind bugfix`：执行 “dispatch + test-fix” 闭环，并沉淀 first-pass 指标
- `rayman review-loop` 每轮会生成标准化 diff 摘要：`.Rayman/runtime/review_loop.last.diff.md`
- `rayman first-pass-report`：输出一次通过率报告（`.Rayman/runtime/telemetry/first_pass_report.*`），含“首轮通过率 vs round1 改动规模”相关性
- `rayman single-repo-upgrade`：一键执行单仓库深度增强链路（质量优先：context/update → test-fix → review-loop → first-pass → baseline/trend → telemetry-export → release-gate(project)）
- `rayman single-repo-upgrade --RiskMode strict --ApproveHighRisk`：高风险改动启用严格门禁时的显式确认入口（会触发注意力提醒）
- `rayman single-repo-upgrade --AutoResetCircuit 1`：执行链路前自动重置 Circuit Breaker 预算，避免历史累计预算导致误熔断（可用 `--NoAutoResetCircuit` 关闭）
- `rayman single-repo-kpi --Window 30`：生成单仓库 KPI 看板（first-pass 成功率、平均修复轮次、CFR、MTTR、人工介入率）
- `rayman single-repo-kpi` 还会输出 `circuit_breaker_trip_rate`、熔断原因 TOP，以及“最近7次 vs 前7次”短周期趋势对比
- `rayman prompts list|show|apply`：列出或应用 `.github/prompts/*.prompt.md` 模板
- `rayman metrics`：查看 rules/check 遥测统计（支持 `--limit N` / `--run-id ID`）
- `rayman metrics --json`：输出机器可读 JSON（便于 CI/看板消费）
- `rayman metrics --assert-max-fail-rate 10 --assert-max-avg-ms 8000`：将遥测统计作为门禁断言
- `rayman trend --days 7`：生成每日趋势报告（`.Rayman/runtime/telemetry/daily_trend.md`）
- `rayman trend --source .Rayman/runtime/telemetry/first_pass_runs.tsv --days 14`：基于 first-pass 数据生成趋势
- `rayman baseline-guard`：比较近期窗口与历史基线，输出 `PASS/WARN/BLOCK`
- `rayman baseline-guard --source .Rayman/runtime/telemetry/first_pass_runs.tsv --report-only`：first-pass 基线守卫（不阻断）
- `rayman telemetry-export`：生成可归档的遥测产物包（含 JSON 校验、趋势报告、基线报告）
- `rayman dist-sync`：Windows 原生校验 `.Rayman` 与 `.Rayman/.dist` 是否同步
- `rayman diagnostics-residual`：检查 release_gate 源脚本与 `.dist` 一致性并输出“诊断残留”报告（`.Rayman/state/diagnostics_residual_report.*`）
- `rayman release-gate`：执行发布闸门并生成 `.Rayman/state/release_gate_report.md`
- `rayman release-gate -Mode project`：项目模式（推荐业务项目，初始化优先；对非 Git 临时目录、历史发布包版本差异、MCP/RAG 运行态探活失败等项按 PASS 记录）
- `rayman release-gate -Mode standard`：标准治理模式（适合 RaymanAgent 自身仓库）
- `rayman release-gate --Mode project --AllowNoGit`：在非 Git 临时环境中启用 project 初始化豁免（按 PASS 记录）；standard 模式仍保持严格 FAIL
- `rayman release-gate --Mode project --AllowNoGit --json`：输出机器可读 JSON（stdout + `.Rayman/state/release_gate_report.json`）
- `rayman release-gate --Mode project --AllowNoGit --IncludeResidualDiagnostics`：在 gate 中附带“诊断残留自检”结果（非阻断，便于识别语言服务缓存类误报）
- 启用 `--IncludeResidualDiagnostics` 时，`release_gate_report.md` 会额外输出“诊断缓存提示”专栏，提示是否可能是语言服务缓存误报
- `rayman migrate-rag`：迁移旧路径 `.Rayman/state` 下的向量库到 `.rag/<命名空间>`
- `rayman package-dist`：生成精简可分发包（默认剔除向量库/运行时/日志）
- `rayman clean`：治理型清理（默认清理 sandbox 临时目录、runtime/tmp、测试 telemetry bundle；支持 `--keep-days`、`--dry-run`、`--aggressive`、`--copy-smoke-artifacts`）
- `rayman snapshot`：生成本地回滚快照（输出到 `.Rayman/runtime/snapshots`）
- `rayman doctor`：只读健康检查（规则引擎 profile=doctor）
- `rayman doctor --copy-smoke`：复制 `.Rayman` 到临时目录并执行初始化烟测（默认会净化 `runtime/logs` 历史产物）
- `rayman doctor --copy-smoke --scope wsl|host|all|sandbox`：指定 smoke 时 Playwright 检查范围（默认 `wsl`，`--strict` 场景建议按环境显式指定）
- `rayman dev`：执行开发态规则链路（profile=dev）
- `rayman release`：发布门禁（profile=release，包含 issues 必须闭环）



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
- `RAYMAN_AUTO_INSTALL_TEST_DEPS`（默认 `1`）：`test-fix` 前自动安装缺失测试依赖。
- `RAYMAN_REQUIRE_TEST_DEPS`（默认 `1`）：测试依赖仍缺失时是否阻断测试流程。
- `RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL`（默认 `1`）：`test-fix` 重试阶段是否执行常见依赖修复动作（如 dotnet restore/npm ci 等）。
- `RAYMAN_USE_SANDBOX`（默认 `0`）：`test-fix` 默认在本机执行；设置为 `1` 可恢复 Docker sandbox 执行路径。
- `RAYMAN_DOTNET_CHANNEL`（默认 `LTS`）：dotnet-install 安装 channel（Windows/WSL）。
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
- `RAYMAN_FIRST_PASS_WINDOW`（默认 `20`）：`first-pass-report` 默认统计窗口。
- `RAYMAN_REVIEW_LOOP_MAX_ROUNDS`（默认 `2`）：`review-loop` 最大轮数。

说明：默认是“自动补全并阻断失败”。如需临时关闭，可显式设置对应变量为 `0`（例如 `RAYMAN_AUTO_INSTALL_TEST_DEPS=0`）。

## 打包与拷贝净化策略

- `rayman package-dist` 默认剔除 `runtime/logs`，减少旧环境噪声。
- 若使用 `-IncludeRuntimeFiles` 或 `-IncludeLogs`，默认仍会净化历史产物；如需保留历史，可加：
  - `-KeepRuntimeHistory`
  - `-KeepLogHistory`
- `rayman doctor --copy-smoke` 在临时复制目录中默认会净化 `runtime/logs` 后再执行 setup。
