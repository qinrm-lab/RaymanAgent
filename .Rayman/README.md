# Rayman v164
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
Agent Memory 默认写入 `.Rayman/state/memory/`，采用 `episodic -> summarizer -> semantic` 三层结构；运行时状态写入 `.Rayman/runtime/memory/status.json`。
`setup.ps1` 会优先预热 Agent Memory，本地 embedding 模型不可用时自动降级为 lexical fallback，并把状态写入 runtime。
`setup.ps1` 会幂等清理废弃记忆数据；若检测到 `.Rayman` 来自其他工作区副本，还会把 Agent Memory 数据库与 memory runtime 重置为空，避免旧项目记忆串到新项目。
检测到跨工作区拷贝时，legacy `.rag/` 根目录也会在预清理阶段直接删除，不再复用旧向量库。
`setup.ps1` 还会删除引用 legacy RAG 路径的历史 snapshot manifest / archive，避免废弃快照继续占用空间。
已有 `.rayman.env.ps1` 不需要删除重建，setup 会自动补齐缺失的 heartbeat 默认项。
外部分发副本在首次 `setup` 后，还会自动补齐工作区根目录 `.rayman.project.json`，并生成标准 workflow：`.github/workflows/rayman-project-fast-gate.yml`、`.github/workflows/rayman-project-browser-gate.yml`、`.github/workflows/rayman-project-full-gate.yml`。这些 consumer workflow / 配置默认只保留在本地，不建议提交到 external workspace 的 Git。RaymanAgent 源仓库不会自动注入这 3 个 consumer workflow。

### 在 VS Code / Codex 中怎么启动

如果你要把 Rayman 安装到另一个**本机可访问的业务工作区**，现在推荐分两步：

```powershell
rayman.ps1 workspace-register
```

这一步只需要在 **RaymanAgent source workspace** 执行一次。它会把当前 **已发布的 Rayman 快照** 注册到用户级状态，安装全局 `rayman-here` launcher，并在 VS Code stable 用户任务里写入手动入口 `Rayman: Bootstrap Current Workspace` 和隐藏的 folder-open 自动升级任务。

之后到了任意目标工作区，直接执行：

```powershell
rayman-here
```

或在 VS Code 里运行：

- `Rayman: Bootstrap Current Workspace`

它会自动从已注册的 `RaymanAgent` source workspace 拉取可分发 `.Rayman/`，执行目标工作区的 `.\.Rayman\setup.ps1`，并默认追加 `copy-self-check`。

如果你更喜欢继续从 source workspace 直接指定目标路径，也可以执行：

```powershell
rayman.ps1 workspace-install --target D:\work\YourProject
```

这个命令只会复制 **`.Rayman/`** 到目标工作区，然后自动执行目标工作区的 `.\.Rayman\setup.ps1`；不会把整个 `RaymanAgent` 根目录塞进业务仓库。`workspace-install` 现在默认会追加 `copy-self-check`；如果你明确要跳过，才传 `--no-self-check`。

手工方式仍然是它的底层原理。也就是把 `.Rayman/` 整个目录拷到目标工作区根目录后，Windows 上的最小启动步骤统一是：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.Rayman\setup.ps1
rayman.ps1 agent-capabilities --sync
rayman.ps1 context-update
```

- 在 **VS Code** 里，核心是先跑一次 `setup.ps1`。它会补齐 `.vscode/tasks.json`、`.vscode/settings.json`、`.vscode/launch.json`、`.github/copilot-instructions.md`、`AGENTS.md`、`.codex/config.toml` 等运行资产。
- 在 **Codex** 里，不需要单独再装一套 “RaymanAgent 环境”；同一个工作区里只要上述 3 步跑完，Codex 读取的就是该工作区的 `AGENTS.md`、`.Rayman/CONTEXT.md`、`.Rayman/context/skills.auto.md` 和 `.codex/config.toml`。
- 如果你只是把 `.Rayman` 拷过去但还没跑 `setup.ps1`，VS Code/Codex 都只能看到静态文件，不能算完成环境搭建。
- 外部业务工作区的推荐入口现在是：先在 `RaymanAgent` 执行一次 `rayman.ps1 workspace-register` 发布当前快照，之后首次安装时在目标工作区直接跑 `rayman-here` 或 VS Code 任务 `Rayman: Bootstrap Current Workspace`。
- `workspace-register` 还会安装用户级 `rayman-codex-desktop-bootstrap` launcher，并写入 Startup 自启脚本；登录后的 Codex Desktop 会按 `~/.codex/sessions` 发现已安装 `.Rayman` 的 workspace，幂等拉起 shared `win-watch.ps1`。
- `workspace-register` 也会托管用户级 `~/.codex/config.toml` 的 Rayman managed `notify` block，并刷新 `~/.codex/notify.ps1`，让 Codex Desktop / VS Code 的完成提醒继续复用同一套 `RAYMAN_ALERT_*` 声音配置。
- `rayman.ps1 workspace-install --target <workspacePath>` 继续保留，作为 source workspace 侧的高级/脚本化入口。
- 对已经安装过 `.Rayman` 的工作区，VS Code 之后每次 reload / 打开都会先自动比较当前工作区和已登记快照；只有版本或快照 fingerprint 发生变化时才会自动升级。
- 如果担心分发副本不完整，先运行 `bash ./.Rayman/init.sh`；它会调用 `scripts/repair/ensure_complete_rayman.sh`，优先从 `.Rayman/.dist` 自愈缺失资产。
- 如果要验证“这份拷贝对 VS Code / Codex 都能独立工作”，跑 `rayman copy-self-check --strict`。

对 **RaymanAgent 源仓库本身** 也是同样的启动方式。区别只在于：

- source workspace 允许跟踪 authored `.Rayman/` 源码；
- source workspace 的 worker debug fallback 只会精确 allowlist 当前 `WorkerSmokeApp` fixture；external workspace 继续完全排除 `.Rayman` 内项目；
- RaymanAgent 源仓库的 IDE 入口优先使用 `RaymanAgent.slnx`；若本地再次生成 `RaymanAgent.sln`，应视为 runtime 噪声，可直接删除；
- external workspace 会把 `.Rayman/**`、`.codex/config.toml`、生成的 `.github/*` / `.vscode/*` 当作本地资产处理，默认不建议提交。

## 拷贝后源码管理噪声控制（默认开启）

- `setup.ps1` 保留全量资产生成，同时会在末尾自动注入 SCM 忽略规则：external workspace 默认写入共享的 `.gitignore`，RaymanAgent source workspace 默认写入本地 `.git/info/exclude`。
- external workspace 默认只保留业务源码、业务文档，以及 `.<SolutionName>/` 下的 requirements / agentic 文档；会忽略整个 `.Rayman/`、`.SolutionName`、`.rayman.project.json`、`.rayman.env.ps1`、`.cursorrules`、`.clinerules`、`.codex/config.toml`、`.github/copilot-instructions.md`、`.github/model-policy.md`、`.github/instructions/`、`.github/agents/`、`.github/skills/`、`.github/prompts/`、`rayman-project-*.yml`、生成的 `.vscode/tasks.json` / `.vscode/settings.json` / `.vscode/launch.json`，以及 `bin/`、`obj/`、`.artifacts/`、`test-results/` 等构建噪声。
- RaymanAgent source workspace 允许跟踪 authored `.Rayman/` 源码、模板和文档，但默认忽略本地/生成资产，例如 `.Rayman/context/skills.auto.md`、`.Rayman/state/`、`.Rayman/runtime/`、`.Rayman/logs/`、`.Rayman/temp/`、`.Rayman/tmp/`、`.Rayman/mcp/*.bak`、`.Rayman/release/*.zip`、`.Rayman/release/*.tar.gz`、`.Rayman/release/*notes*.md`、`.rayman.env.ps1`、`.cursorrules`、`.clinerules`、`.vscode/*`、`.env`、`.codex/config.toml`。
- setup 末尾会输出 `modified/added/untracked/total` 统计；超过软阈值（默认 `100`）时，会提示主要来源目录。
- 若检测到 `.Rayman/**`、`.SolutionName`、`.rayman.project.json`、`.rayman.env.ps1`、`.cursorrules`、`.clinerules`、`.codex/config.toml`、`.github/copilot-instructions.md`、`.github/model-policy.md`、`.github/instructions/**`、`.github/agents/**`、`.github/skills/**`、`.github/prompts/**`、`rayman-project-*.yml`、`.vscode/tasks.json`、`.vscode/settings.json`、`.vscode/launch.json` 已被 Git 跟踪：
  - external workspace 会严格阻断，并给出精确 `git rm -r --cached -- ...` 修复命令；这类仓库只建议提交业务源码、业务文档，以及 `.<SolutionName>/` 下的 requirements / agentic 文档。
  - Rayman 源仓库允许 authored `.Rayman/` 与 `.SolutionName`，但仍会阻断本地/生成资产入库。
- 非 Rayman 的常见产物目录（`.dotnet10/`、`dist/`、`publish/`、`.tmp/`、`.temp/`）若被 Git 跟踪，会在 setup / release-gate 中单独告警，但默认不阻断。
- 如需手工覆盖该行为，仍可在工作区级 `.rayman.env.ps1` 中直接设置 `RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS=1`。
- 从现在开始，`rayman.ps1` 路由的命令在结束后还会自动执行一次共享 post-command hygiene：清理安全的 runtime/temp 残留，自动解除 Git 已跟踪的 Rayman 生成资产，并把摘要写入 `.Rayman/runtime/post_command_hygiene.last.json`。
- 这条 post-command hygiene 默认只对剩余的非 Rayman 脏树做告警，不会阻断下一次自动化；如需临时关闭，可在工作区 `.rayman.env.ps1` 中设置 `RAYMAN_POST_COMMAND_HYGIENE_ENABLED=0`。

## Doctor（推荐）

```bash
bash ./.Rayman/run/doctor.sh
```

`doctor` 现在会优先执行 `agent-contract`，先确认 agent 资产、instructions、context 与 auto-skills 契约没有漂移，再继续规则与回归检查。

## 自动化测试 Lane

Rayman 现在把自动化测试拆成 4 条 lane，避免所有检查都堆进一个大脚本里：

- `fast-contract`：快速契约检查，覆盖 requirements/layout、release checklist、regression guard、config sanity、agent contract、`.dist` 同步与 JSON contract。
- `logic-unit`：PowerShell `Pester 5` + Bash `bats-core`，优先覆盖路径归一化、scope/fallback、版本 token、WinApp readiness 等容易回归的判定逻辑。
- `host-smoke`：最小真实环境冒烟，重点看 CLI help、`ensure-winapp -Json`、`ensure-playwright -Json`、worker loopback `discover -> use -> status -> exec -> sync -> debug -> clear` 以及 runtime 报告结构。
- `release`：继续由 `release-gate` 负责最终发布门禁，并消费 `.Rayman/runtime/test_lanes/*.report.json` 与 `.Rayman/runtime/project_gates/*.report.json`；缺少 Linux Bash 测试工具时会记为 `WARN`，真实断言失败仍记为 `FAIL`。

## 项目工作流标准化

拷贝 `.Rayman` 到实施工程后，标准入口统一为：

- `rayman fast-gate`：PR 级快速门禁，默认覆盖 requirements layout、protected assets、项目 build、轻量 project smoke，并输出 `.Rayman/runtime/project_gates/fast.report.json`
- `rayman browser-gate`：浏览器/项目冒烟门禁，默认消费 `.rayman.project.json` 的 `browser_command` 与 `extensions.project_browser_checks`
- `rayman full-gate`：完整门禁，先执行项目 release checks，再执行 `release-gate -Mode project`，并输出 `.Rayman/runtime/project_gates/full.report.json`
- `rayman copy-self-check`：分发副本自检；`--strict` 现在除了 SCM tracked-noise 合同，还会验证外部分发副本 setup 后可以跑通标准 `fast-gate`
- Windows 上的 project gate 现在会在每个 gate command 结束后自动清理本次新启动的 workspace-owned child/orphan 进程；外部工作区无需再各自补一套 `dotnet run` 残留兜底脚本，正常升级 Rayman 后会继承该行为。

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
- WSL 下 `run_bats_tests.sh` 会接受 `command -v bats` 或 `~/.dotnet/tools/bats`；不要求 Windows host 的 `PATH` 里额外存在 `bats`
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

## Hermes-Inspired Agent Governance

- `rayman.ps1 context-audit` 会在消费 prompt/context 前审计 `AGENTS.md`、受管 prompt / instruction 资产、`skills.auto.md`、受信任 `SKILL.md`、以及 session handover 摘要，识别 prompt override、secret exfiltration cue 和 oversized context。
- `rayman.ps1 context-update` 默认以 `warn` 模式运行 context audit；`rayman dispatch` 与 `rayman.ps1 review-loop` 默认以 `block` 模式运行。审计结果会写入 `.Rayman/runtime/context_audit.last.json`、`.Rayman/runtime/context_audit.last.md`，并同步进 dispatch / reflection telemetry。
- `rayman.ps1 skills -Action list|audit` 由 `.Rayman/config/skills_registry.json` 驱动。默认只信任 Rayman 管理的 bundled skill roots；external roots 只有显式 allowlist 才会进入 `skills.auto.md`。registry / audit 只要无效，`detect_skills.ps1` 就会 fail-closed：`skills.auto.md` 只保留 suppression 文案，不再渲染任何 trusted manifests。
- `rayman.ps1 memory-search` 现在是统一 recall 入口，会同时搜索 Agent Memory 和 `.Rayman/state/sessions` 生成的 session recall 记录。输出会带 `source_kind`，并显式报告 `session_search_backend=fts5|lexical`。
- `.Rayman/config/event_hooks.json` 默认开启本地 JSONL sink，把 context audit、skills audit、dispatch/review、memory search/summarize、session checkpoint、rollback restore、prompt eval 统一写入 `.Rayman/runtime/events/*.jsonl`；webhook sink 默认关闭。
- `rayman.ps1 rollback -Action list|diff|restore` 是 session-backed checkpoint 的用户入口；`rayman snapshot` 继续保留 archive-style backup 语义，不会被 rollback 覆盖。
- `rayman.ps1 prompts -Action eval` 使用 `.Rayman/config/prompt_eval_suites.json` 运行受管 prompt suites，并把报告写入 `.Rayman/runtime/prompt_evals/`。`.RaymanAgent/agentic/evals.md` 继续作为人工验收与 release review 索引。

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
- 默认提醒面为 `log-first`：人工介入/错误优先写终端与 `.Rayman/runtime/attention.last.json`；默认不开 Windows toast 和语音，但会保留声音提醒。
- `setup.ps1` 完成、`rayman.ps1` / `rayman` 的交互式成功命令，以及 Codex CLI 的 `agent-turn-complete` 都会走统一提醒链路；默认完成提醒与人工等待提醒都会出声。
- Codex CLI 每次 `agent-turn-complete` 的原生 `notify` 现在改由工作区 `.codex/config.toml` 的 Rayman managed `notify` block 托管，不再依赖用户级 `~/.codex/config.toml` 是否保留旧 hook。
- Rayman 会把 per-turn `notify.wav` 统一指向 `.Rayman/scripts/codex/codex_notify.ps1`，并复用同一套 `RAYMAN_ALERT_*` 声音配置。
- `workspace-register` 会额外托管用户级 `~/.codex/notify.ps1` 与 `~/.codex/config.toml` 的 notify block，作为 Codex Desktop / VS Code 会话结束提醒的全局兜底；脚本会优先按 payload 里的 `cwd` 回到对应 workspace，再委托该 workspace 的 `.Rayman/scripts/codex/codex_notify.ps1`。
- 当 `rayman codex ...` 已依赖 Codex 原生 `notify` 时，Rayman 会抑制同一次完成上的 wrapper done alert，避免双响。
- `init` 与 VS Code / Codex Desktop 默认不再单独拉起 detached `alert-watch`；改为默认启用嵌入到共享 `win-watch.ps1` 的 attention scan，并默认监控 VS Code/Codex 窗口标题中的人工确认信号。
- Codex Desktop 本地 session 识别同时兼容旧 `originator=Codex Desktop` 和当前 `originator=codex_vscode` / `source=vscode` 的 `session_meta`；只要 `cwd` 能匹配当前 workspace，就会被纳入 desktop bootstrap / shared watcher / network-resume 候选。
- `attention-watch` 还会对同类窗口做标题归一化与聚合：短时间内多个相似窗口只提醒一次，并在提醒文案里汇总数量与样例标题。
- `attention-watch` 会再按高/中/低优先级分层：Sandbox 启动失败/超时/错误码类窗口会用更醒目的高优先级标题；Target 选择/应用更改类窗口走中优先级；普通确认类窗口走低优先级。

### 声音自检

- 可直接运行：`rayman.ps1 sound-check`
- 该命令只支持 Windows 主机；它不会只看 `PlaySync()` 返回值，而是会真实触发两条提醒链路并要求你确认：
  - `manual`：调用 `request_attention.ps1`，验证“需要你回答问题时”是否会响
  - `done`：调用 `codex_notify.ps1`，验证“任务结束时”是否会响
- 每一步都会要求输入：
  - `1` = 听到了
  - `2` = 没听到
  - `q` = 取消
- 自检结果会写到：
  - `.Rayman/runtime/sound_check.last.json`
  - `.Rayman/runtime/sound_check.last.md`
- 报告会包含当前 `sound_path`、对应开关状态、best-effort `Win32_SoundDevice` 列表，以及 `manual/done` 两步各自的确认结果。

环境变量：

- `RAYMAN_ALERTS_ENABLED=0`：关闭全部提醒
- `RAYMAN_ALERT_MANUAL_ENABLED=0`：关闭人工介入提醒
- `RAYMAN_ALERT_SURFACE=log|toast|silent`：控制提醒落点；默认 `log`
- `RAYMAN_ALERT_DONE_ENABLED=0`：关闭完成提醒（默认开启）
- `RAYMAN_ALERT_SOUND_ENABLED=0`：关闭 `notify.wav` 播放（默认开启）
- `RAYMAN_ALERT_SOUND_DONE_ENABLED=0`：关闭“完成提醒”的 `notify.wav` 播放（默认开启）
- `RAYMAN_ALERT_SOUND_PATH=<绝对路径>`：指定要播放的 `.wav` 文件；Windows 默认使用 `C:\Users\<user>\.rayman\codex\notify.wav`，若旧 `C:\Users\<user>\.codex\notify.wav` 仍存在，Rayman 会优先迁移复用
- `RAYMAN_ALERT_TTS_ENABLED=0`：关闭语音播报（默认关闭）
- `RAYMAN_ALERT_TTS_DONE_ENABLED=0`：关闭“完成提醒”语音播报（默认关闭）
- `RAYMAN_ALERT_WATCH_FAIL_MAX_SECONDS=<秒>`：`win-watch.ps1` 失败提醒持续时长（默认 180）
- `RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED=0`：关闭共享 `win-watch.ps1` 内置的 attention scan（默认开启）
- `RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED=0`：关闭 prompt sync 场景下的额外 attention 自启钩子（默认开启）
- `RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED=0`：关闭 VS Code / Codex 窗口加入 attention scan 目标列表（默认开启）
- `RAYMAN_AUTO_SAVE_WATCH_ENABLED=0`：在共享 `win-watch.ps1` 内启用 auto-save（默认关闭）
- `RAYMAN_NETWORK_RESUME_WATCH_ENABLED=0`：关闭共享 `win-watch.ps1` 内置的 provider-target network resume watcher（默认开启）
- `RAYMAN_NETWORK_RESUME_THRESHOLD_SECONDS=<秒>`：provider 持续不可达且鼠标键盘持续无输入的阈值（默认 `1800`）
- `RAYMAN_NETWORK_RESUME_THROTTLE_WAIT_SECONDS=<秒>`：provider 返回高 demand / rate limit / overload 一类失败后，键鼠持续无输入多久再自动继续（默认 `300`）
- `RAYMAN_NETWORK_RESUME_POLL_MS=<毫秒>`：network resume 轮询间隔（默认 `5000`）
- `RAYMAN_NETWORK_RESUME_PROBE_TIMEOUT_MS=<毫秒>`：provider 探测超时（默认 `5000`）
- `RAYMAN_NETWORK_RESUME_RETRY_SECONDS=<秒>`：同一任务下一次恢复边沿允许再次原生续接前的冷却时间（默认 `300`）
- `RAYMAN_NETWORK_RESUME_MAX_ATTEMPTS=<次数>`：同一未完成任务最多自动原生续接次数（默认 `3`）
- `RAYMAN_NETWORK_RESUME_CODEX_PROBE_URL=<https-url>`：Codex/OpenAI provider 目标探测地址（默认 `https://api.openai.com/`）
- `RAYMAN_NETWORK_RESUME_COPILOT_PROBE_URL=<https-url>`：Copilot/GitHub provider 目标探测地址（默认 `https://api.github.com/`）
- `RAYMAN_NETWORK_RESUME_DESKTOP_SOURCE_ENABLED=0`：关闭从 Codex Desktop 本地 session / tui 日志提取 network-resume 候选（默认开启）
- `RAYMAN_CODEX_DESKTOP_WATCH_AUTO_START_ENABLED=0`：关闭用户级 Codex Desktop bootstrap 自动拉起 shared watch（默认开启）
- `RAYMAN_CODEX_DESKTOP_BOOTSTRAP_POLL_MS=<毫秒>`：desktop bootstrap 轮询 `~/.codex/sessions` 的间隔（默认 `5000`）
- `RAYMAN_CODEX_DESKTOP_SESSION_LOOKBACK_HOURS=<小时>`：扫描 Codex Desktop 本地 session 的回看窗口（默认 `12`）
- `RAYMAN_CODEX_DESKTOP_STOP_GRACE_SECONDS=<秒>`：desktop session 无新活动后，回收 desktop 自动拉起 watcher 的宽限期（默认 `900`）
- `RAYMAN_WORKER_AUTO_SYNC_ENABLED=0`：启用独立的 worker staged auto-sync watcher（默认关闭）
- `RAYMAN_WORKER_AUTO_SYNC_POLL_MS=<毫秒>`：worker auto-sync 轮询间隔（默认 `2000`）
- `RAYMAN_WORKER_AUTO_SYNC_DEBOUNCE_SECONDS=<秒>`：检测到源码变化后等待的去抖时间（默认 `5`）
- `RAYMAN_WORKER_AUTO_SYNC_RETRY_SECONDS=<秒>`：worker staged sync 失败后的重试冷却（默认 `30`）
- `RAYMAN_ALERT_WINDOW_KEYWORDS=a,b,c`：覆盖默认强提示短语白名单（仅建议在你确实知道要监控哪些窗口标题时使用）
- `RAYMAN_ALERT_WINDOW_SANDBOX_KEYWORDS=a,b,c`：仅覆盖 Sandbox 窗口白名单
- `RAYMAN_ALERT_WINDOW_VSCODE_KEYWORDS=a,b,c`：仅覆盖普通 VS Code/其他窗口白名单

改回低打扰/静默行为（显式 opt-in）：

- `RAYMAN_ALERT_SURFACE=toast`
- `RAYMAN_ALERT_DONE_ENABLED=0`
- `RAYMAN_ALERT_SOUND_ENABLED=0`
- `RAYMAN_ALERT_SOUND_DONE_ENABLED=0`
- `RAYMAN_ALERT_TTS_ENABLED=1`
- `RAYMAN_NETWORK_RESUME_WATCH_ENABLED=0`
- `RAYMAN_NETWORK_RESUME_THROTTLE_WAIT_SECONDS=300`
- `RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED=0`
- `RAYMAN_ALERT_WATCH_ON_PROMPT_ENABLED=0`
- `RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED=0`
- `RAYMAN_AUTO_SAVE_WATCH_ENABLED=1`
- `RAYMAN_WORKER_AUTO_SYNC_ENABLED=1`

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
- 如果 Playwright 汇总状态已经显示 `scope=wsl` 且 `success=true` 呢？
  - 说明本次没有走 Windows Sandbox；无需手工补关闭，问题应优先从 host / copy-smoke / VS Code 窗口回收链路排查。
- 为什么默认会优先走 wsl？
  - 默认 `RAYMAN_PLAYWRIGHT_SETUP_SCOPE=wsl`；若 WSL 路径失败，setup 会自动回退 `scope=host` 以优先保证初始化完成。
- 如何强制严格 sandbox？
  - 显式设置 `RAYMAN_PLAYWRIGHT_SETUP_SCOPE=sandbox` 后再执行 setup；该模式失败会阻断，不做自动降级。

## VS Code 打开自动启动 Rayman（Windows）

- 如果目标工作区还没有 `.Rayman`，先执行一次用户任务 `Rayman: Bootstrap Current Workspace`；它会调用已注册的 `rayman-here`，把 `.Rayman` 拉进当前 workspace 并自动完成 setup / self-check。
- 运行一次 `init.cmd` 后，Rayman 会自动写入 `.vscode/tasks.json` + `.vscode/settings.json` + `.vscode/launch.json`。
- 已经安装过 `.Rayman` 的工作区在 VS Code folder-open 时还会先跑一个隐藏的 auto-upgrade 任务；它只会检查和升级已安装工作区，不会把 Rayman 自动塞进普通空文件夹。
- 之后每次你用 VS Code 打开该 solution/workspace，默认只会触发一个自动任务：
- `Rayman: Folder Open Bootstrap`
- 默认 profile=`conservative`：只同步必跑 watcher/session 去重与 pending task；`daily health`、`context refresh`、轻量依赖检查改为 stale-only。
- runtime 报告：`.Rayman/runtime/vscode_bootstrap.last.json`
- 可选 profile：`RAYMAN_VSCODE_BOOTSTRAP_PROFILE=conservative|active|strict`
- 原来的 `Rayman: Auto Start Watchers`、`Rayman: Check Pending Task`、`Rayman: Daily Health Check`、`Rayman: Check Win Deps`、`Rayman: Check WSL Deps` 仍保留，但改为手动任务，不再在 folderOpen 时并发触发。
- `Rayman: Stop Watchers` 会显式传 `-IncludeResidualCleanup -OwnerPid ${env:VSCODE_PID}`，用于清理当前 workspace 的残留 watcher / MCP / exitwatch 进程树。
- Rayman 只负责清理自己启动的 watcher / bootstrap / 依赖检查残留进程；VS Code 扩展自身的 `wsl.exe ... codex app-server` 不属于 Rayman 清理范围。
- strict `copy-self-check` / `copy smoke` 现在只会回收已确认归属临时 workspace 的 VS Code 进程；如果归属无法证明，会记录 `skipped ambiguous vscode cleanup`，不会再为了收尾去强杀当前工作窗口。

环境变量：

- `RAYMAN_VSCODE_AUTO_START_INSTALL_ENABLED=0`：禁用 `init` 自动写入 VS Code 自动任务
- `RAYMAN_VSCODE_AUTO_UPGRADE_ENABLED=0`：禁用已安装工作区的 VS Code 自动升级
- `RAYMAN_VSCODE_FOLDER_OPEN_BOOTSTRAP_ENABLED=0`：禁用 `Rayman: Folder Open Bootstrap`
- `RAYMAN_VSCODE_BOOTSTRAP_PROFILE=conservative|active|strict`：控制 folderOpen 默认行为；默认 `conservative`
- `RAYMAN_AUTO_START_PROMPT_WATCH_ENABLED=0`：自动启动时不拉起 prompt-watch
- `RAYMAN_AUTO_START_ATTENTION_WATCH_ENABLED=0`：自动启动时在共享 `win-watch.ps1` 内启用 attention scan
- `RAYMAN_AUTO_SAVE_WATCH_ENABLED=0`：自动启动时在共享 `win-watch.ps1` 内启用 auto-save
- `RAYMAN_NETWORK_RESUME_WATCH_ENABLED=0`：自动启动时关闭 provider-target network resume watcher
- `RAYMAN_NETWORK_RESUME_CODEX_PROBE_URL=<https-url>`：改 Codex/OpenAI provider 探测地址；默认 `https://api.openai.com/`
- `RAYMAN_VSCODE_EXIT_LINKED_STOP_ENABLED=0`：关闭 VS Code owner 退出后按 session 自动回收后台服务
- `RAYMAN_ALERT_WATCH_VSCODE_WINDOWS_ENABLED=1`：如确实需要，再显式开启对普通 VS Code 窗口的监控

network resume 说明：

- 候选失败现在有两条输入面：`dispatch/review-loop` 写出的 `.Rayman/runtime/agent_runs/last.json`，以及当前 workspace 命中的 Codex Desktop 本地 session（`~/.codex/sessions/**/rollout-*.jsonl`，必要时补读 `~/.codex/log/codex-tui.log`）。
- 只有当当前 provider 目标持续不可达超过阈值，且这段时间内鼠标键盘都没有动作，shared `win-watch.ps1` 才会把最新失败任务标记为可自动续接。
- 若最新失败看起来是 provider `high demand / rate limit / overload`，而不是硬断网，那么在键鼠持续无输入满 5 分钟后，也会尝试自动继续。
- 目标恢复后会按 provider 目标可达性继续判断，而不是只看“任意网站能不能打开”。
- `dispatch` / `review-loop` 任务继续只会对 Codex 调用 `codex exec resume --last`；desktop 直连会话优先按 session id 调用 `codex resume <id>`，只有确认仍属于该 workspace 最近会话时才允许回退到 `codex resume --last`。
- Copilot/GitHub 仅记录 `unsupported_native_resume` 状态，不会自动重放旧命令。
- 若原生续接失败，Rayman 只写诊断和 quiet attention，不会回退成重新执行上次 `executed_command`。

## LAN Worker / Remote .NET Debugging

Rayman 现在支持 `开发机 -> 工作机` 的局域网 worker 链路。共享 worker 正式支持“多个研发机 / 多个 source workspace 独立发现并连接同一台工作机”，但隔离模型固定为 **multi-client staged-only**。v1 仍假设环境是**受控独立局域网**；如果后续进入普通办公网、跨网段或不可信网络，必须显式配置 auth / pairing。

约束：

- Worker 仅支持 Windows。
- Worker 依赖已登录的交互式用户会话。
- 一台工作机的一个 workspace 对应一个 worker。
- 开发机可以发现多台 worker，但一次只绑定 1 台 active worker。
- 多个研发机 / 项目可以共享同一台 worker；隔离依赖 `client_context = machine_name + canonical source workspace path` 的稳定 hash，而不是靠不同 token。
- 共享 worker 只承诺 `staged` 并发隔离；`attached` 不再作为共享模型的一部分。
- 远程源码级调试当前只承诺 `.NET-first`。

首次部署：

0. 开发机如需直接把最小 worker 包导出到 U 盘 / 共享目录，可执行：
   - `rayman.ps1 worker export-package --target H:\RaymanAgent.Worker`
   - 或在 `rayman.ps1 worker` 子命令里选择导出流程
   - 该命令会写入 `.Rayman/`、工作机 `.rayman.env.ps1`、`INSTALL-WORKER.txt`，以及 `all.* / collect-worker-diag.* / repair-worker-encoding.* / download\**` 等官方根级资产，并记住上一次成功导出的目标目录
1. 将 `H:\RaymanAgent.Worker` **整个目录原封不动**复制到工作机的稳定 workspace 根目录，例如 `D:\RaymanWorker\RaymanAgent`；不需要维护完整源码仓库。
2. 工作机 `.rayman.env.ps1` 至少提供：
   - `$env:RAYMAN_WORKER_LAN_ENABLED = '1'`
   - 可选：`$env:RAYMAN_WORKER_AUTH_TOKEN = '<shared-secret>'`
   - 可选：`$env:RAYMAN_WORKER_NAME`、`$env:RAYMAN_WORKER_VSDBG_PATH`
   - 这里的 `RAYMAN_WORKER_AUTH_TOKEN` 只是 worker 控制口令，不是 OpenAI / Codex 的 AI token；导出包默认不会复制任何 AI 凭据
3. 首选在该目录本地执行：`.\all.bat`
4. `all.bat` 会串行完成编码修复、诊断刷新、`worker install-local` 和 post-check，并把摘要写到 `.\log\all-summary.log`。
5. 这会注册按用户登录自启的 `Rayman Worker` 任务，并立即拉起轻量 host。
6. `install-local` 会优先读取 `RAYMAN_WORKER_VSDBG_PATH`；若未预置，则自动把 `vsdbg` 安装到 `.Rayman/tools/vsdbg/`。
   - 若包内存在 `download\vsdbg\vsdbg.exe`，会先复制这套本地离线包到 `.Rayman\tools\vsdbg\`，只有本地包缺失时才会尝试联网下载
   - 若包内存在 `download\powershell7\*.msi`，则该目录也会保留最新稳定版 PowerShell 7 x64 安装包，便于离线排障；导出时会尽量自动刷新到最新版
7. 若启用 `RAYMAN_WORKER_LAN_ENABLED=1`，`install-local` 会 best-effort 检查/补齐 worker 的 Windows Firewall 入站规则，并把 `firewall_ready` / `firewall_error` 写入 install result 与 `worker status`。
8. 为了避免 host 意外退出后长期失联，`install-local` 会通过 Task Scheduler 直接启动 worker，并配置自动重启策略；若当前会话无法直接通过 Task Scheduler 启动，会自动回退到一次性的进程拉起。
9. 若只想手工兜底安装，仍可直接执行：`rayman.ps1 worker install-local`

开发机日常使用：

1. 建议在开发机 `.rayman.env.ps1` 固定 `$env:RAYMAN_WORKER_SYNC_MODE = 'staged'`；多个研发机/项目可以复用同一个 `$env:RAYMAN_WORKER_AUTH_TOKEN`，真正的会话隔离由 `client_context` 保证。只有在受控 LAN 之外或需要额外保护时，才额外强化 auth / pairing。
2. 发现工作机：`rayman.ps1 worker discover`
3. 查看缓存：`rayman.ps1 worker list`
4. 绑定 active worker：`rayman.ps1 worker use --id <workerId>`
5. 查看远端状态：`rayman.ps1 worker status`
6. 先确认 `worker status` 中 `debugger_ready=true`
7. 执行远端命令：`rayman.ps1 worker exec -- dotnet build`

源码同步：

- staged：开发机把当前源码快照打包后下发到工作机 staging 目录
  - `rayman.ps1 worker sync --mode staged`
  - 每个研发机 / source workspace 都会落到 `.Rayman/runtime/worker/staging/<client_id>/stage-<bundle_id>/`
  - 如需改完代码后自动下发：在开发机 `.rayman.env.ps1` 开启 `RAYMAN_WORKER_AUTO_SYNC_ENABLED=1`
  - auto-sync 只会跟踪会进入 staged bundle 的文件；`.env`、`.Rayman/runtime/**`、gitignored 文件不会触发
  - 最近一次 auto-sync 状态会写到 `.Rayman/runtime/workers/auto_sync.last.json`
- attached：共享 worker 默认拒绝；source 端与远端都会 fail-fast 返回结构化错误，避免多个研发机落到同一源码根互相覆盖

VS Code 调试：

1. 先执行 `rayman.ps1 worker status`，确认 `debugger_ready=true`，并检查 `client_session.execution_root` 指向当前客户端自己的 staged root；失败时查看 `debugger_error`
2. 再执行 `Rayman: Worker Debug Prepare`
3. 然后启动：
   - `Rayman Worker: Launch .NET (Active Worker)`
   - `Rayman Worker: Attach .NET (Active Worker)`
4. `worker debug --mode launch|attach` 会在生成 manifest 前自动校验/补齐 `vsdbg`；若失败会返回结构化错误并终止
5. 若自动识别到的目标程序不对，可先传 `--program <path>` 或设置 `RAYMAN_WORKER_DEBUG_PROGRAM`
6. 若 attach，需要输入工作机上的远程进程 PID

远程升级：

- 开发机执行：`rayman.ps1 worker upgrade`
- 当前开发机的 `.Rayman` 包会推送到 active worker，并在工作机上自动切换重启；升级后会重新校验 `vsdbg`

退出远程模式：

- 清空 active worker：`rayman.ps1 worker clear`
- `worker clear` 仍只清本地 active binding，但会 best-effort 通知远端只清理**当前 client** 的 session / staging / debug 状态，不会删除其他研发机的活跃会话
- 清空后 `dispatch` / `review-loop` / `test-fix` 会回退本地执行

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
#### Core
- `[ all ]` `rayman fast-init`：Generate missing requirements only (no installs).
- `[ all ]` `rayman migrate`：Migrate legacy requirements into the standard layout.
- `[ pwsh-only ]` `rayman.ps1 memory-bootstrap`：Probe and prepare the Agent Memory Python runtime.
- `[ pwsh-only ]` `rayman.ps1 memory-summarize`：Drain pending episodic summaries into task summaries and semantic memory.
- `[ pwsh-only ]` `rayman.ps1 memory-search`：Query unified recall across Agent Memory and saved sessions.
#### Diagnostics
- `[ pwsh-only ]` `rayman.ps1 context-audit`：Audit managed context sources for prompt injection and oversize risk.
- `[ pwsh-only ]` `rayman.ps1 skills`：Inspect trusted skill roots and skills audit results.
- `[ all ]` `rayman doctor`：Run read-only health checks.
- `[ all ]` `rayman copy-self-check`：Run copy-initialization smoke verification.
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
- `[ windows-only ]` `rayman.ps1 worker`：Manage shared LAN Rayman Workers with staged sync, exec, debug, and upgrade.
- `[ windows-only ]` `rayman.ps1 workspace-install`：Install distributable .Rayman into a local workspace, run setup, and default self-check.
- `[ windows-only ]` `rayman.ps1 workspace-register`：Register this RaymanAgent source workspace and install the rayman-here bootstrap launcher.
- `[ pwsh-only ]` `rayman.ps1 agent-capabilities`：Sync or inspect Rayman-managed Codex capabilities.
#### Core
- `[ pwsh-only ]` `rayman.ps1 interaction-mode`：Show or change the workspace interaction mode for plan-first ambiguity handling.
#### Diagnostics
- `[ pwsh-only ]` `rayman.ps1 agent-contract`：Check agent assets, instructions, and generated-context contracts.
- `[ windows-only ]` `rayman.ps1 sound-check`：Play manual and done reminder sounds and require explicit user confirmation.
#### Automation
- `[ pwsh-only ]` `rayman.ps1 review-loop`：Run the dispatch plus test-fix review loop.
- `[ pwsh-only ]` `rayman.ps1 first-pass-report`：Generate the first-pass KPI report.
- `[ pwsh-only ]` `rayman.ps1 prompts`：List, show, apply, or eval reusable prompt templates.
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
#### Diagnostics
- `[ all ]` `rayman clean`：Clean runtime, temp, and copy-smoke artifacts.
- `[ all ]` `rayman snapshot`：Create a rollback snapshot under .Rayman/runtime/snapshots.
#### State
- `[ pwsh-only ]` `rayman.ps1 rollback`：List, diff, or restore session-backed checkpoints.
#### Diagnostics
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
- `[ pwsh-only ]` `rayman.ps1 state-save`：Save a named task session and capture an exact stash snapshot.
- `[ pwsh-only ]` `rayman.ps1 state-list`：List named task sessions available for resume.
- `[ pwsh-only ]` `rayman.ps1 state-resume`：Resume a named task session without guessing the latest stash.
- `[ pwsh-only ]` `rayman.ps1 worktree-create`：Create or reuse a named git worktree session for isolated parallel edits.
#### Automation
- `[ pwsh-only ]` `rayman.ps1 test-fix`：Run tests/builds and record repair diagnostics.
#### Release
- `[ pwsh-only ]` `rayman.ps1 dist-sync`：Sync and validate the .Rayman/.dist mirror.
#### Diagnostics
- `[ pwsh-only ]` `rayman.ps1 diagnostics-residual`：Check residual source/dist diagnostics drift.
- `[ pwsh-only ]` `rayman.ps1 context-update`：Regenerate local context and auto-skill artifacts.
- `[ pwsh-only ]` `rayman.ps1 health-check`：Run the daily health check once.
- `[ pwsh-only ]` `rayman.ps1 one-click-health`：Force daily health check and refresh proxy health snapshot.
- `[ pwsh-only ]` `rayman.ps1 proxy-health`：Show the resolved proxy snapshot and sources.
#### Core
- `[ pwsh-only ]` `rayman.ps1 ensure-wsl-deps`：Install or verify WSL-side dependencies.
- `[ windows-only ]` `rayman.ps1 ensure-win-deps`：Check Windows-side dependencies.
#### Release
- `[ pwsh-only ]` `rayman.ps1 single-repo-upgrade`：Run the single-repo deep upgrade flow.
#### Diagnostics
- `[ pwsh-only ]` `rayman.ps1 single-repo-kpi`：Generate the single-repo KPI dashboard.
#### Core
- `[ pwsh-only ]` `rayman.ps1 menu`：Show the interactive command picker.
#### State
- `[ all ]` `rayman transfer-export`：[Agent/Handover] 导出当前工作区及系统状态信息。
- `[ all ]` `rayman transfer-import`：[Agent/Handover] 导入并恢复外部环境及工作区状态信息。
<!-- RAYMAN:COMMANDS:END -->

### Rayman Codex alias 与 profile 术语

- 交互式终端里直接运行 `rayman.ps1 codex`，或在 `rayman.ps1 menu` 里选择 `codex`，都会进入带说明的 Codex 二级菜单。
- Codex 二级菜单会显示当前 workspace、当前绑定 alias、认证状态、最近登录方式、最近原生 session、当前 workspace saved state 摘要，以及当前有效的 Codex execution profile。
- `rayman codex menu` 是可显式调用的二级菜单入口；显式动作如 `rayman codex status --json`、`login`、`login-smoke`、`switch`、`run`、`upgrade` 保持原样。
- `rayman codex login` 会先从 `%APPDATA%\Code\User\globalStorage\storage.json` 读取当前 workspace 绑定的 **VS Code user profile**，再统一接入三种原生登录方式。
- Codex 二级菜单顶层会直接给出 `网页登录`、`Yunyi 登录`、`API 登录`、`设备码登录` 四个入口，并新增一个带冷却保护的 `登录 Smoke` 入口；`管理账号 -> 重新登录` 仍保留通用方式选择。
- 省略 `--alias` 时，Rayman 会先给出一组可选 alias：`main`、已有 alias、推荐第二账号 `gpt-alt`，以及 `custom` 手工输入。
- `rayman codex upgrade` 会查询 npm registry 上 `@openai/codex` 的最新版本，并在当前安装链路属于 npm 全局安装时执行 `npm install -g @openai/codex`。
- `rayman codex login --alias <alias> --mode web|device|api|yunyi` 会执行 Codex 原生登录：在 Windows 上，`web` 会改为服务 Codex Desktop 全局家目录 `~/.codex`；`device` / `api` / `yunyi` 仍保持 alias 专属 `CODEX_HOME`。`web` 对应 `codex login`，`device` 对应 `codex login --device-auth`，`api` 对应 `codex login --with-api-key`，`yunyi` 对应带自定义 `OPENAI_BASE_URL` 的 API key 登录流程。
- `rayman codex login --mode api --api-key-stdin` 只用于非交互输入；交互终端下，Rayman 会安全读取 API Key，不回显明文，也不会把明文写进 JSON 状态或日志。
- `rayman codex login --mode api` 现在会先检测当前进程环境和当前 workspace `.env` 里的 `OPENAI_API_KEY`；若已存在可用 key，则直接走受管 API 模式并完成 alias 绑定，否则才回退到原生 `codex login --with-api-key`。
- 直接 CLI 调用 `rayman codex login` 且未传 `--mode` 时，仍保持旧默认 `device`；通用“登录账号/重新登录”入口会先让你选方式，默认推荐 `web`。
- Windows 上的 `web` / `device` 登录现在默认直接走前台交互，不再先做 hidden-first 启动；只有你显式设置 `RAYMAN_CODEX_LOGIN_ALLOW_HIDDEN=1` 且关闭 `RAYMAN_CODEX_LOGIN_FOREGROUND_ONLY` 时，才会恢复 legacy hidden-first 行为。
- `rayman codex login-smoke --alias <alias> --mode web|device [--force]` 会执行一次真实登录验证，先显示当前预算/冷却，再写 `.Rayman/runtime/codex.login.last.json`；它默认只允许在冷却窗口内做 1 次真实尝试，避免反复触发 OpenAI 登录限制。
- 在 Windows 上，`login-smoke --mode web` 现在不会再用 `hello` 作为长期验收，而是把浏览器登录后的 Codex Desktop `/status` 当作可用性门槛：只有 `/status` 里能看到额度/配额信息，才算网页登录真正可用。
- 如果 Windows `web login-smoke` 浏览器回调成功、但 Desktop `/status` 看不到额度，Rayman 会把它视为失败，保留 `.Rayman/runtime/codex.login.last.json`、Desktop 诊断产物和冷却状态，并回滚这次变更过的本地 auth cache。
- 浏览器成功页里的 localhost callback code/token 不是长期可复用凭据；Rayman 复用的是 Codex Desktop 全局家目录里的持久认证缓存（在 file-store 模式下通常是 `~/.codex/auth.json`）。
- 登录阶段会额外写出 `last_login_mode`、`last_login_strategy`、`last_login_prompt_classification`、`login_smoke_next_allowed_at` 等非敏感诊断，并补充 `auth_scope`、`desktop_codex_home`、`desktop_status_command`、`desktop_status_quota_visible`、`desktop_status_reason`、`desktop_global_cloud_access`，方便区分“alias 已登录”与“Codex Desktop 真正可用”。
- workspace 绑定的事实来源是 `.rayman.env.ps1` 里的 `RAYMAN_CODEX_ACCOUNT_ALIAS` / `RAYMAN_CODEX_PROFILE`；`rayman codex login` / `switch` 会更新这两个值，而不是只改当前终端会话。
- Windows 上当 `RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_ENABLED=1` 时，`Rayman: Folder Open Bootstrap` 和用户级 `rayman-codex-desktop-bootstrap` 会按当前 workspace 绑定自动再应用 `web|api|yunyi` 账号，避免下次打开工作区还要先手工修复 / 重切。
- 登录成功后，Rayman 会把当前 workspace 的 `[projects."<workspace>"] trust_level = "trusted"` 写回当前生效的认证宿主 `config.toml`：Windows `web` 登录会写到 Desktop 全局 `~/.codex/config.toml`，其余模式仍写回 alias 自己的 `config.toml`。
- `rayman codex switch --alias <alias>` 会切换当前 workspace 绑定；如果该 alias 已认证，Rayman 会顺手补齐同一份 workspace trust 配置。
- Codex 二级菜单里的“管理账号”支持：查看 alias 详情、更新默认 Codex execution profile、重新登录（web / API / 设备码）、安全删除 alias、彻底删除 alias。
- 安全删除只会移除 Rayman registry 与已知 workspace 引用，不会删掉该 alias 的 `CODEX_HOME`、本地凭据或 `config.toml`；彻底删除会额外删除 `CODEX_HOME`。
- 对全新 alias，`rayman codex status` 遇到缺少本地凭据文件时会归一化为 `not_logged_in`，避免误报成 `probe_failed`。
- `rayman codex status/login/switch/run` 默认都会先检查 npm registry 最新版本；若当前 Codex CLI 落后且安装来源是 npm，全局升级会先执行，再进入后续动作。
- `rayman codex status --json`、`rayman codex list --json` 和 `.Rayman/runtime/codex.auth.status.json` 现在会额外输出 `auth_mode_last`、`auth_mode_detected`、`auth_source`、`auth_scope`、`desktop_codex_home`、`desktop_auth_present`、`desktop_status_command`、`desktop_status_quota_visible`、`desktop_status_reason`、`desktop_global_cloud_access`、`latest_native_session`、`saved_state_summary`、`recent_saved_states`。
- `latest_native_session` 来自 alias 专属 `CODEX_HOME/session_index.jsonl`；`saved_state_summary` / `recent_saved_states` 来自当前 workspace 的 `.Rayman/state/sessions`，只统计 `backend=codex` 的本地 saved state。
- 下面 3 个概念必须分开：
- `VS Code user profile`：左下角“管理 -> 配置文件”里切换的用户配置文件。
- `Rayman bootstrap profile`：`RAYMAN_VSCODE_BOOTSTRAP_PROFILE=conservative|active|strict`，只控制 folder-open bootstrap 行为。
- `Codex execution profile`：`rayman codex ... --profile <name>` 传给 Codex CLI 的执行 profile。
- `rayman codex status --json` 和 `.Rayman/runtime/codex.auth.status.json` 仍会分别输出 `vscode_user_profile`、`account_alias`、`profile`，避免继续把不同含义都写成裸 `profile`。
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
- `RAYMAN_CODEX_LOGIN_FOREGROUND_ONLY`（默认 `1`）：Windows 上 `web/device` 登录默认只走前台交互启动。
- `RAYMAN_CODEX_LOGIN_ALLOW_HIDDEN`（默认 `0`）：显式允许恢复 legacy hidden-first 登录启动策略。
- `RAYMAN_CODEX_LOGIN_SMOKE_COOLDOWN_MINUTES`（默认 `30`）：`rayman codex login-smoke` 的冷却窗口。
- `RAYMAN_CODEX_LOGIN_SMOKE_MAX_ATTEMPTS`（默认 `1`）：单个 alias+mode+workspace 在冷却窗口内允许的真实 smoke 次数。
- `RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_ENABLED`（默认 `1`）：在 Windows 的 folder-open / Codex Desktop active-session bootstrap 中自动再应用当前 workspace 绑定的 `web|api|yunyi` alias。
- `RAYMAN_CODEX_WORKSPACE_BINDING_AUTO_APPLY_RETRY_SECONDS`（默认 `300`）：上次自动再应用失败后，bootstrap 再次尝试前的最小重试间隔。
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
- `RAYMAN_AGENT_PIPELINE`（默认 `planner_v1`）：Agent 默认执行链路；支持 `planner_v1|legacy`，`legacy` 会回退到旧 dispatch/review-loop 路径。
- `RAYMAN_AGENT_DOC_GATE`（默认 `1`）：是否开启 `.RaymanAgent/agentic/` 文档硬门禁；关闭后仍保留 planner/reflection 本地流程，但不再因文档闭环缺失阻断。
- `RAYMAN_AGENT_OPENAI_OPTIONAL`（默认 `auto`）：是否自动探测 OpenAI/Codex 可选增强；支持 `auto|off`。开启时会把 background mode / compaction / prompt optimizer 明确写入 delegated Codex optional requests；在 delegated executor 尚未落地前，这些能力会显示为 `disabled_until_supported`，并强制回退到本地 fallback，而不会伪装成已可执行的直连 API 路径。
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
- `RAYMAN_POST_COMMAND_HYGIENE_ENABLED`（默认 `1`）：是否在每次 `rayman.ps1` 命令结束后自动执行共享脏树卫生检查与安全残留清理。

说明：默认是“自动补全并阻断失败”。如需临时关闭，可显式设置对应变量为 `0`（例如 `RAYMAN_AUTO_INSTALL_TEST_DEPS=0`）。

## Agent Capabilities

- Rayman 继续把 `.Rayman/mcp/mcp_servers.json` 留给自身 runtime MCP，例如 `sqlite`；Codex 专用能力改由工作区级 `.codex/config.toml` 管理，而该文件现在同时承载 4 个 Rayman-managed slice：`capabilities`、`project_doc`、`profiles`、`subagents`。
- Codex 内置 sandbox 负责 Agent 执行隔离；本 README 中的 “Windows Sandbox” / `scope=sandbox` 专指 Playwright / PWA UI 基座，不等同于已移除的通用测试 wrapper。
- 当前内置 capability registry 位于 `.Rayman/config/agent_capabilities.json`，默认提供：
  - `openai_docs`：为 Codex 注入官方 OpenAI Docs MCP（`openaiDeveloperDocs`）。
- `web_auto_test`：为 Codex 注入 Playwright MCP（`playwright`），并保留 `rayman ensure-playwright` / `rayman.ps1 pwa-test` 作为降级链路。
- `winapp_auto_test`：为 Codex 注入 Rayman 本地 Windows 桌面 MCP（`raymanWinApp`），并保留 `rayman.ps1 ensure-winapp` / `rayman.ps1 winapp-test` 作为降级链路。
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
- 默认 Agent 链路现在是 `plan -> tool/subagent select -> execute -> reflect -> verify -> doc close`；`dispatch` 会先刷新 `.RaymanAgent/agentic/plan.current.*` 与 `tool-policy.*`，再把 tool-policy 转成实际的 execution contract；`review-loop` 会写出 `reflection.current.*` 并在 reflection=`done` 前拒绝把运行视为成功。
- `.RaymanAgent/.RaymanAgent.requirements.md` 现在是 agentic 文档硬门禁入口，必须显式链接 `.RaymanAgent/agentic/plan.current.md`、`.RaymanAgent/agentic/tool-policy.md`、`.RaymanAgent/agentic/reflection.current.md`、`.RaymanAgent/agentic/evals.md` 及其 JSON 附件。
- OpenAI optional features 现在只通过 delegated Codex 生效，并会把 `backend_order`、`optional_requests`、`prepare_commands` / `prepare_results` 写入 `dispatch` summary，避免 planner 继续只停留在文档层。
- `first-pass-report` 现在会汇总 `plan_id`、`replan_count`、`selected_tools`、`fallback_count`、`doc_gate_pass`、`acceptance_closed`、`reflection_outcome`，让 planner/reflection 维度真正进入 telemetry。
- 如果 multi-agent 不可用，Rayman 会保留 MCP / 单代理流程，并把降级原因写进 report/context，避免阻断基础工作流。
- Copilot 不做等价 MCP 注入；它共享 instructions、任务入口和 Rayman fallback 命令。
- Copilot Memory、GitHub.com coding-agent 的 model picker / Auto model selection 属于平台能力；Rayman 只做文档和检测，不在仓库内假装已托管。
- hosted model selection 边界与推荐用法见 `.github/model-policy.md`；当前功能盘点与增强优先级见 `.Rayman/release/FEATURE_INVENTORY.md`、`.Rayman/release/ENHANCEMENT_ROADMAP_2026.md`。
- `web_auto_test` 负责网页自动化；`winapp_auto_test` 负责 Windows 桌面自动化。MAUI 在 v1 仅指 Windows 桌面 target，不包含 Android/iOS/macOS。

### 交互模式（多路径 / 目标不明确时先问多少）

- 每个工作区都可以通过 `.rayman.env.ps1` 中的 `RAYMAN_INTERACTION_MODE=detailed|general|simple` 持久化控制“先给 plan 还是先执行”。
- 硬门槛：只要 Rayman 判断提示不足够明确，且歧义会影响目标、范围、实现路径、风险、测试期望、目标工作区或回滚方式，就必须先给出选项、说明结果差异，并写出明确验收标准；该规则不依赖 Codex Plan Mode。
- 默认是 `detailed`：
  只要目标不明确、存在明显多路径、或不同方案结果差异明显，就先给出 plan、解释各选项含义与结果、明确验收标准，再继续。
- `general`：
  只在会明显改变结果、范围、实现路径、风险、测试期望或返工成本的歧义上先停下来确认；一旦停下，同样必须给出选项和验收标准；次要细节可带默认假设继续。
- `simple`：
  只在高风险、不可逆、跨工作区、发布/架构级、或明显可能走错方向时先停下来确认；一旦停下，同样必须给出选项和验收标准；其余按推荐默认继续并显式写出假设。
- `full-auto` 只表示改动审批已放行，不表示可以替用户决定需求或在多方案里自己拍板。
- 可直接执行：
  - `rayman.ps1 interaction-mode --show`
  - `rayman.ps1 interaction-mode --set detailed|general|simple`
  - 或在 `rayman.ps1 menu` 中选择 `interaction-mode`

## 打包与拷贝净化策略

- `rayman package-dist` 默认剔除 `runtime/logs`，减少旧环境噪声。
- 若使用 `-IncludeRuntimeFiles` 或 `-IncludeLogs`，默认仍会净化历史产物；如需保留历史，可加：
  - `-KeepRuntimeHistory`
  - `-KeepLogHistory`
- `rayman doctor --copy-smoke` 在临时复制目录中默认会净化 `runtime/logs` 后再执行 setup。
