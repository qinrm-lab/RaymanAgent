# Codex 账户管理修复总结

## 概述

本次修复解决用户在 Codex 账户切换、登录菜单和 release_gate 功能中遇到的三个关键问题。

## 修复详情

### 1. 账户切换后 Codex 桌面上下文不更新

**问题**

- 用户运行 `rayman.ps1 codex login --alias qinrm1 --mode web` 切换到网页登录账号后
- Codex 插件仍然显示旧的账号信息（yunyi2）
- 根本原因：`Invoke-ActionLogin` 缺少桌面激活调用，导致 Codex 的全局上下文没有更新

**修复方案**

- 在 `Invoke-ActionLogin` 函数中添加了 `Invoke-RaymanCodexDesktopAliasActivation` 调用
- 这样登录完成后会立即更新 Codex 的桌面全局上下文，使新别名在工作区立即生效
- 实现方式与 `Invoke-ActionSwitch` 保持一致，确保两个入口的行为统一

**修改的文件**

- `.Rayman/scripts/codex/manage_accounts.ps1` (Invoke-ActionLogin 函数)
- `.Rayman/.dist/scripts/codex/manage_accounts.ps1` (同步)

**关键代码块**

```powershell
# Activate desktop Codex context so that the new alias is immediately reflected
$desktopActivation = Invoke-RaymanCodexDesktopAliasActivation -WorkspaceRoot $resolvedWorkspace -Alias $normalizedAlias -Account $account -Mode ([string]$modeChoice.mode)
```

### 2. 登录菜单未根据模式筛选别名

**问题**

- 当用户选择特定登录模式（如 Yunyi）时，菜单仍显示所有别名
- 未配置 Yunyi 的别名出现在列表中，造成困惑和额外噪音
- 需要智能过滤：不同模式下只显示支持该模式的别名

**修复方案**

- 为 `Get-LoginAliasRows` 函数添加了 `-FilterByMode` 开关参数
- 实现了基于模式的别名过滤逻辑：
  - **yunyi 模式**：只显示已配置 Yunyi config 的别名
  - **web 模式**：显示所有别名
  - **device/api 模式**：显示所有别名
- 在 `Resolve-LoginAliasChoice` 中自动启用过滤（当指定了模式时）

**修改的文件**

- `.Rayman/scripts/codex/manage_accounts.ps1` (Get-LoginAliasRows + Resolve-LoginAliasChoice)
- `.Rayman/.dist/scripts/codex/manage_accounts.ps1` (同步)

### 3. Release_gate 功能审查

**当前状态**

- Release_gate 功能已经非常完整，包含 20+ 项检查
- 最近的提交中已包含多项优化：
  - Agent 路由与首轮通过率契约检查
  - 单仓库增强风险快照
  - 自动化测试 Lane 结果消费
  - DotNet 摘要字段契约

## 验证步骤

### 测试账户切换修复

```powershell
# 1. 切换到网页登录
rayman.ps1 codex login --alias qinrm1 --mode web

# 2. 验证结果
rayman.ps1 codex status
# 应显示 alias=qinrm1，mode=web，且 desktop context 已更新
```

### 测试菜单过滤修复

```powershell
# 1. 选择 Yunyi 模式
rayman.ps1 codex login --mode yunyi
# 菜单应只显示已配置 Yunyi 的别名

# 2. 选择 Web 模式
rayman.ps1 codex login --mode web
# 菜单显示所有别名
```

### 验证 release_gate

```powershell
# 运行完整检查
./.Rayman/rayman.ps1 release-gate

# 运行项目初始化模式（宽松）
./.Rayman/rayman.ps1 release-gate -Mode project
```

## 影响范围

- 向后兼容：所有修改都是新增功能或增强
- 自动启用：菜单过滤默认启用（当指定模式时）
- 无配置需求：无需用户额外配置
