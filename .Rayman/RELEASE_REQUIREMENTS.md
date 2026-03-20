# Rayman 发布验收标准（Release Requirements）

> 当前版本： v161

> 适用范围：本工作区内的 **Rayman 工具链发布包（vXXX.zip）**。
>
> 目标：把“是否可交付”从手工试运行，变成 **可重复、可自动化、可追溯** 的验收。
>
> 说明：本文件只约束 Rayman 自身（初始化/脚本/监控/沙盒/配置/生成规范），
> **不约束你的业务项目本身的测试是否通过**。
>
> 显式迁移说明：Rayman 通用测试 sandbox wrapper 已废弃，Agent / Codex 执行隔离改由 Codex 内置 sandbox 负责；Windows Sandbox 相关要求仅保留给 PWA / Playwright UI 调试基座。

## 1. 问题闭环与停止条件

- **必须把“本次输入/本次变更”引入的问题全部闭环**，才允许停止/打包发布。
- Rayman 以 `.Rayman/runtime/issues.open.md` 作为“未闭环问题清单”：
  - 若文件存在且包含未完成项（`- [ ]`），则 **发布验收失败**。
  - 若存在冲突：以最新输入的问题描述为准（覆盖旧描述）。
- 若验收标准冲突且需要人工决策，必须在日志中记录决策（Rayman 会提示并写入 `.Rayman/runtime/decision.log`）。
- 任何 gate 绕过（例如无 Git / 跳过 diff / 允许 unsigned）必须：
  - 显式提供 `RAYMAN_BYPASS_REASON`
  - 将决策写入 `.Rayman/runtime/decision.log`

## 2. 不覆盖原有功能的回归保护

- 任何修复/增强 **不得删除或破坏** 既有命令入口（如 `init.* / win-watch.* / self-check.* / run/check.*`）。
- 发布前必须运行 **回归守护检查**：验证关键脚本与关键标记块仍存在（skills 注入、prompt 同步、watch 等）。

## 3. 随机抽查测试

- 发布前必须执行随机抽查（默认抽查 3 项）：
  - 从 Rayman 的关键功能入口中随机抽查执行（doctor/check 等轻量命令）。
  - 抽查种子写入 `.Rayman/runtime/spotcheck.seed`，保证可复现。
  - 任一抽查失败则发布验收失败。

---

## 0. 术语

- **WorkspaceRoot**：你的项目根目录（包含 `.Rayman/` 的那一层）。
- **RaymanDir**：`WorkspaceRoot/.Rayman`。
- **Codex Built-in Sandbox**：Codex runtime 提供的代码执行隔离；Rayman 不再维护 `RaymanDir/run/sandbox/workspace` 包装层。
- **Windows Sandbox**：Rayman PWA / Playwright UI 调试基座使用的 Windows 宿主隔离环境。
- **ProjectName**：Rayman 识别的项目名（通常为 WorkspaceRoot 目录名）。
- **ProjectRequirements**：`.${ProjectName}.requirements.md`，项目级需求与验收文件。
- **Win Proxy Mode = system**：Windows 端不管理/不监控系统代理。

---

## 1. 必须满足（阻断发布）

### 1.1 包结构与文件完整性（静态）

发布包必须至少包含：

- `.Rayman/common.ps1`
- `.Rayman/win-preflight.ps1`
- `.Rayman/win-check.ps1`
- `.Rayman/win-oneclick.ps1`
- `.Rayman/win-watch.ps1`
- `.Rayman/win-exitwatch.ps1`
- `.Rayman/rayman-win.cmd`
- `.Rayman/release/FEATURE_INVENTORY.md`
- `.Rayman/release/ENHANCEMENT_ROADMAP_2026.md`
- `.Rayman/scripts/dynproxy/*`
- `.Rayman/context/*`
- `.Rayman/RELEASE_REQUIREMENTS.md`

缺失任何一项，均不得发布。

---

### 1.2 PowerShell 语法必须 0 错误（Fail-Fast）

- `.Rayman/**/*.ps1` 必须全部通过 PowerShell AST 解析
- 任一脚本存在语法错误时：
  - 必须在 **win-preflight.ps1** 阶段终止
  - 输出文件路径、行号、错误原因


#### 1.2.1 入口脚本必须无“首行隐式命令”（运行前可发现的问题必须拦截）

- **禁止** `.ps1` 文件在首个非空、非注释行出现可执行命令（例如单独的 `\`）
- 允许的首个非空行只能是：
  - `param(...)`
  - `Set-StrictMode ...` / `$ErrorActionPreference = 'Stop'`（初始化防御）
  - 注释 / `#requires` / `using module` 等声明性语句
- 发布前必须执行 **逐脚本 Dry-Run 预执行**（在隔离环境中）以捕获运行前即可暴露的 Fail-Fast 错误，例如：
  - `CommandNotFoundException`（如首行误命令）
  - `VariableIsUndefined`（严格模式下未赋值变量）
  - 其他初始化阶段即可触发的异常

> 推荐实现（示例思路）：在 `win-preflight.ps1` 中枚举 `.Rayman/**/*.ps1`，对每个脚本用 `pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command` 进行隔离加载/执行入口校验；任一失败立即终止并打印脚本路径+异常堆栈。

#### 1.2.2 Windows 右键解压兼容（CRLF 与执行位必须自动修复）

- 允许用户使用 **Windows 资源管理器 → 右键解压缩** 获取 Rayman 发布包。
- `bash ./.Rayman/init.sh` 在执行任何子脚本之前，必须自动完成：
  - **CRLF → LF 归一化**：对 `.Rayman/**/*.sh`（以及必要时的 `.ps1/.cmd`）去除行尾 `\r`。
  - **可执行位修复**：对 `.Rayman/**/*.sh` 自动 `chmod +x`。
- 任何归一化/修复必须：
  - **幂等**（重复执行不会改变语义）
  - **可追溯**（至少在 init 日志中打印“已修复/无需修复”）

---

### 1.3 WorkspaceRoot 与路径健壮性

- 必须正确识别 WorkspaceRoot
- 不允许生成 `.Rayman/.Rayman` 套娃目录
- cmd → PowerShell 传参不得触发：
  - `Illegal characters in path`

---

### 1.4 Windows 系统代理默认策略

- 默认 `Win proxy mode = system`
- Rayman 在默认模式下：
  - 不得修改系统代理
  - 不得写入代理相关注册表

---

### 1.5 VSCode 启动与窗口绑定

`win-oneclick.log` 中必须明确记录：

- VSCode launcher 路径
- wrapper pid → window pid 映射
- 至少识别到 1 个 workspace 窗口 PID
- exit watcher 成功启动

---

## 2. 项目级 requirements 生成

### 2.1 自动生成 `.ProjectName.requirements.md`

在 WorkspaceRoot 下，Rayman 必须：

- 自动生成文件：

  ```text
  .${ProjectName}.requirements.md
  ```

- 若文件已存在：
  - 不得覆盖用户已有内容
  - 仅允许追加 Rayman 管理的区块（带明确标记）

---

### 2.2 requirements 文件内容要求

`.${ProjectName}.requirements.md` **必须至少包含**：

- 项目名称与 WorkspaceRoot 路径
- 功能清单（Features）
- 对应的验收标准（Acceptance Criteria）
- 明确区分：
  - 项目功能验收
  - Rayman 工具行为假设（如 Codex Built-in Sandbox、Playwright 测试方式）

---

### 2.3 与 RELEASE_REQUIREMENTS 的关系

- `.${ProjectName}.requirements.md`：
  - 描述 **项目功能与验收**
- `RELEASE_REQUIREMENTS.md`：
  - 描述 **Rayman 工具自身的发布验收**
- 两者职责必须严格区分，不得混用

---

## 3. Agent 执行隔离与 UI Sandbox

### 3.1 Codex Built-in Sandbox

- Rayman 不再提供通用测试 wrapper（如 `test_in_sandbox_*`）或 `RaymanDir/run/sandbox/workspace` 执行目录。
- Agent / Codex 的代码执行隔离依赖 Codex 内置 sandbox。
- `test-fix`、`review-loop`、`dispatch` 触发的本地命令允许直接走当前宿主 / Windows bridge 路径。

---

### 3.2 Windows Sandbox（PWA / UI）

- Windows Sandbox 仅用于第 7 节的 Playwright / PWA UI 调试基座。
- 该链路的 bootstrap / ready / copy smoke 要求保持有效，不等同于已移除的通用测试 wrapper。

---

## 4. VSCode 集成

### 4.1 VSCode Tasks

- 不再要求提供 `Rayman: Test (Sandbox)`。
- VSCode 仍需能直接识别 Rayman 相关任务入口，无需用户手工补配。

---

### 4.2 init 行为

- init 后必须保证：
  - `.vscode/tasks.json` 存在
  - `.vscode/settings.json` 存在
- VSCode 能直接识别 Rayman 相关任务

---

## 5. 稳定性与防回归

### 5.1 PowerShell 安全约束

- 不得使用以下自动变量名作为普通变量：
  - `$PID`
  - `$Error`
  - `$PSItem`

---

### 5.2 错误处理

- 严重错误必须 fail-fast
- 不允许 silently ignore 关键异常
- 日志必须可追溯错误阶段

---

## 6. 发布 Gate

- 所有 `vXXX.zip`：
  - 必须 100% 满足本文件
- 新功能：
  - 只能 **追加新的验收条目**
  - 不得删除历史条目
- 签名信任链：
  - 仅允许 verify-only；私钥不得存放在仓库内。
  - 公钥指纹必须固定在 `.Rayman/release/public_key.sha256`，并与 `public_key.pem` 一致。
  - 发布说明需包含当前指纹（参考 `.Rayman/release/SIGNING.md`）。
- telemetry 产物新鲜度：
  - 发布抽查阶段默认必须校验 `.Rayman/runtime/artifacts/telemetry/index.json`
  - `index.summary.latest_bundle.age_hours` 必须 `<= 24`（可通过 `RAYMAN_RELEASE_TELEMETRY_MAX_AGE_HOURS` 调整）
  - 默认允许自动生成一次新 telemetry bundle 后重试（`RAYMAN_RELEASE_TELEMETRY_AUTO_EXPORT=1`）
  - 若需绕过，必须显式设置 `RAYMAN_ALLOW_STALE_TELEMETRY=1` 且提供 `RAYMAN_BYPASS_REASON`

---

> 本文件的目标：
> **让 Rayman 的发布与演进具备“工程记忆”，而不是反复试错。**

---

## 7. PWA UI 调试基座

目标：让 WSL 下的 Codex/VSCode 通过 Playwright 自动化脚本间接操作浏览器 UI，从而对 .NET 10 PWA 进行“可重复、可自动化”的调试与回归。

### 7.1 WSL2 侧准备（init.sh 默认执行，幂等）

- 自动安装 Node.js + npm（apt）
- 自动安装 Playwright Chromium 与依赖（`npx playwright@latest install --with-deps chromium`）
- 尝试导出 .NET HTTPS dev cert 到 `.Rayman/runtime/devcert.pfx`（best effort，不阻断）
- 可通过 `RAYMAN_SKIP_PWA=1` 跳过

### 7.2 Windows Sandbox 侧准备（Windows 一键 init.ps1）

- `powershell -File .Rayman/init.ps1` 将自动生成：
  - `.Rayman/runtime/windows-sandbox/rayman-pwa.wsb`
- Sandbox 启动后自动执行：
  - `.Rayman/scripts/pwa/sandbox/bootstrap.ps1`
  - 安装 .NET SDK 10、Node.js LTS、Playwright + Chromium
  - 若存在 `.Rayman/runtime/devcert.pfx` 则尝试导入 Root（best effort）

---

## 7.3 Windows Sandbox 一键闭环

目标：Windows 侧 `init.ps1` **不仅生成 `.wsb`**，还要在默认情况下 **自动启动 Sandbox 并等待 bootstrap 完成**，从而在运行 UI 测试前让 Sandbox 环境“确定就绪”。

### 7.3.1 主机侧（init.ps1）要求

- 运行：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .Rayman/init.ps1
  ```

  必须在默认情况下：
  - 自动启动 Windows Sandbox（WindowsSandbox.exe）
  - 轮询等待 bootstrap 状态文件出现并进入 `ready`
  - 若 bootstrap 失败或超时：必须 fail-fast 并输出日志路径

- 允许通过环境变量跳过自动启动：
  - `RAYMAN_SKIP_SANDBOX_START=1`

### 7.3.2 Sandbox 内（bootstrap.ps1）可观测性要求

- 必须将**状态**与**日志**写入宿主机可见目录（MappedFolders）：
  - 状态：`.Rayman/runtime/windows-sandbox/status/bootstrap_status.json`
  - 日志：`.Rayman/runtime/windows-sandbox/status/bootstrap.log`
- `bootstrap_status.json` 必须至少包含：
  - `success`（bool）
  - `phase`（`starting|installing|ready|failed`）
  - `message` / `error`
  - `startedAt` / `finishedAt`

---

## 8. 机器可读清单（Rayman 会执行）

> 新功能只允许追加新的验收条目；不得删除/弱化历史条目。

<!-- RAYMAN:RELEASE_CHECKLIST -->
- MUST_EXIST: .Rayman/init.sh
- MUST_EXIST: .Rayman/init.ps1
- MUST_EXIST: .Rayman/self-check.sh
- MUST_EXIST: .Rayman/run/doctor.sh
- MUST_EXIST: .Rayman/run/check.sh
- MUST_EXIST: .Rayman/scripts/release/validate_release_requirements.sh
- MUST_EXIST: .Rayman/scripts/ci/validate_requirements.sh
- MUST_EXIST: .Rayman/scripts/dynproxy/README.md
- MUST_EXIST: .Rayman/scripts/pwa/ensure_playwright_wsl.sh
- MUST_EXIST: .Rayman/scripts/pwa/ensure_playwright_ready.ps1
- MUST_EXIST: .Rayman/scripts/pwa/prepare_windows_sandbox.ps1
- MUST_EXIST: .Rayman/scripts/pwa/prepare_windows_sandbox_cache.ps1
- MUST_EXIST: .Rayman/scripts/pwa/sandbox/bootstrap.ps1
- MUST_EXIST: .Rayman/scripts/proxy/sandbox_proxy_bridge.ps1
- MUST_EXIST: .Rayman/scripts/release/spotcheck_release.sh
- MUST_EXIST: .Rayman/scripts/release/regression_guard.sh
- MUST_EXIST: .Rayman/scripts/release/assert_workspace_hygiene.sh
- MUST_EXIST: .Rayman/scripts/release/assert_dist_sync.sh
- MUST_EXIST: .Rayman/scripts/release/assert_dist_sync.ps1
- MUST_EXIST: .Rayman/scripts/release/maintain_decision_log.sh
- MUST_EXIST: .Rayman/scripts/release/maintain_decision_log.ps1
- MUST_EXIST: .Rayman/scripts/release/contract_update_from_prompt.sh
- MUST_EXIST: .Rayman/scripts/backup/snapshot_workspace.sh
- MUST_EXIST: .Rayman/scripts/backup/snapshot_workspace.ps1
- MUST_EXIST: .Rayman/scripts/utils/clean_workspace.sh
- MUST_EXIST: .Rayman/scripts/utils/clean_workspace.ps1
- MUST_EXIST: .Rayman/scripts/utils/ensure_project_test_deps.sh
- MUST_EXIST: .Rayman/scripts/utils/ensure_project_test_deps.ps1
- MUST_EXIST: .Rayman/scripts/agents/resolve_agents_file.sh
- MUST_RUN: bash ./.Rayman/scripts/release/spotcheck_release.sh
- MUST_RUN: bash ./.Rayman/scripts/release/checklist.sh
- MUST_RUN: bash ./.Rayman/scripts/release/contract_update_from_prompt.sh

- MUST_EXIST: .Rayman/scripts/release/issues_gate.sh
- MUST_EXIST: .Rayman/scripts/fast-init/fast-init.sh
- MUST_EXIST: .Rayman/rayman
- MUST_EXIST: .Rayman/rayman.cmd
- MUST_EXIST: .Rayman/rayman.ps1
<!-- /RAYMAN:RELEASE_CHECKLIST -->
