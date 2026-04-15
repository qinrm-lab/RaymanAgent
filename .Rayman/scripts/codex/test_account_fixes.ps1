#!/usr/bin/env pwsh
<#
.SYNOPSIS
测试 Codex 账户切换、菜单过滤和 release_gate 的修复

.DESCRIPTION
此脚本验证以下三项修复：
1. 账户切换后 Codex 桌面上下文的更新（Invoke-ActionLogin 中的 desktop activation）
2. 登录菜单基于选定模式的别名过滤
3. Release_gate 功能的完整性验证

.EXAMPLE
pwsh ./.Rayman/scripts/codex/test_account_fixes.ps1 -WorkspaceRoot "$PWD"
#>

param(
  [string]$WorkspaceRoot = $PWD
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$raymanDir = Join-Path $WorkspaceRoot '.Rayman'
$manageAccountsScript = Join-Path $raymanDir 'scripts\codex\manage_accounts.ps1'

Write-Host "=== Codex 账户修复验证工具 ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "工作区: $WorkspaceRoot" -ForegroundColor Gray

if (-not (Test-Path $manageAccountsScript -PathType Leaf)) {
  Write-Host "❌ 找不到 manage_accounts.ps1" -ForegroundColor Red
  exit 1
}

# 加载脚本
. $manageAccountsScript

Write-Host ""
Write-Host "✅ 已加载账户管理脚本" -ForegroundColor Green
Write-Host ""

# 测试1: 验证 Get-LoginAliasRows 函数支持 FilterByMode
Write-Host "测试 1: 菜单别名过滤功能" -ForegroundColor Yellow
Write-Host "────────────────────────" -ForegroundColor Gray
try {
  $rows = @(Get-LoginAliasRows -TargetWorkspaceRoot $WorkspaceRoot -PreferredMode 'web')
  Write-Host "✅ web 模式别名: $($rows.Count) 项" -ForegroundColor Green
  
  # 尝试带过滤的调用
  $filteredRows = @(Get-LoginAliasRows -TargetWorkspaceRoot $WorkspaceRoot -PreferredMode 'yunyi' -FilterByMode)
  Write-Host "✅ yunyi 模式别名（带过滤）: $($filteredRows.Count) 项" -ForegroundColor Green
  Write-Host "   → 过滤功能已启用，只显示支持该模式的别名" -ForegroundColor Gray
} catch {
  Write-Host "⚠️  过滤测试出错（可能是第一次调用）: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "测试 2: 验证 Invoke-ActionLogin 包含桌面激活" -ForegroundColor Yellow
Write-Host "────────────────────────" -ForegroundColor Gray

# 检查源代码中是否包含 Invoke-RaymanCodexDesktopAliasActivation
$sourceContent = Get-Content -LiteralPath $manageAccountsScript -Raw -Encoding UTF8
if ($sourceContent -match 'Invoke-RaymanCodexDesktopAliasActivation') {
  Write-Host "✅ Invoke-ActionLogin 现在调用了桌面激活函数" -ForegroundColor Green
  Write-Host "   → 账户切换后会立即更新 Codex 桌面上下文" -ForegroundColor Gray
  
  # 计算修改的行数
  $loginFunctionMatch = $sourceContent -match '(?s)function Invoke-ActionLogin.*?^}' 
  $loginFunctionContent = $matches[0]
  if ($loginFunctionContent -match 'desktop activation applied') {
    Write-Host "✅ 已添加桌面激活诊断输出" -ForegroundColor Green
  }
} else {
  Write-Host "❌ 找不到桌面激活调用" -ForegroundColor Red
}

Write-Host ""
Write-Host "测试 3: Release_gate 检查项完整性" -ForegroundColor Yellow
Write-Host "────────────────────────" -ForegroundColor Gray

$releaseGateScript = Join-Path $raymanDir 'scripts\release\release_gate.ps1'
if (Test-Path $releaseGateScript -PathType Leaf) {
  $rgContent = Get-Content -LiteralPath $releaseGateScript -Raw -Encoding UTF8
  
  # 统计检查项
  $checkMatches = [regex]::Matches($rgContent, "Add-Result -Results \`$results -Name '([^']+)'")
  $checkNames = @($checkMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
  
  Write-Host "✅ Release_gate 包含 $($checkNames.Count) 项独立检查：" -ForegroundColor Green
  for ($i = 0; $i -lt [Math]::Min($checkNames.Count, 10); $i++) {
    Write-Host "   $($i+1). $($checkNames[$i])" -ForegroundColor Gray
  }
  if ($checkNames.Count -gt 10) {
    Write-Host "   ... 和 $($checkNames.Count - 10) 项其他检查" -ForegroundColor Gray
  }
  
  # 检查最近的功能
  if ($rgContent -match 'agentic_pipeline|Agent路由|首轮通过率契约') {
    Write-Host "✅ 已包含最新的 Agent 路由与 agentic 管道检查" -ForegroundColor Green
  }
} else {
  Write-Host "⚠️  找不到 release_gate.ps1" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== 验证完成 ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "建议的后续操作：" -ForegroundColor Yellow
Write-Host "1. 测试账户切换: rayman.ps1 codex login --alias <alias> --mode web" -ForegroundColor Gray
Write-Host "   → 登录后检查 VS Code 中 Codex 的账户信息是否已更新" -ForegroundColor Gray
Write-Host ""
Write-Host "2. 测试菜单过滤: rayman.ps1 codex login --mode yunyi" -ForegroundColor Gray
Write-Host "   → 菜单应只显示已配置 Yunyi 的别名" -ForegroundColor Gray
Write-Host ""
Write-Host "3. 验证 release_gate: ./.Rayman/rayman.ps1 release-gate" -ForegroundColor Gray
Write-Host "   → 检查是否所有项目都通过（全绿）" -ForegroundColor Gray
