param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\\..\\..\\.." | Select-Object -ExpandProperty Path)
)
$ErrorActionPreference = 'Stop'

$RaymanDir = Join-Path $WorkspaceRoot '.Rayman'
$RuntimeDir = Join-Path $RaymanDir 'runtime'
$SandboxDir = Join-Path $RuntimeDir 'windows-sandbox'
New-Item -ItemType Directory -Force -Path $SandboxDir | Out-Null

# Host-visible status/log directory written by the Sandbox bootstrap.
$StatusDir = Join-Path $SandboxDir 'status'
New-Item -ItemType Directory -Force -Path $StatusDir | Out-Null

$WsbPath = Join-Path $SandboxDir 'rayman-pwa.wsb'
$MappingInfoPath = Join-Path $SandboxDir 'mapping.json'

function Get-RaymanAclRiskInfo([string]$Path) {
  $result = [ordered]@{
    Path               = $Path
    HasRisk            = $false
    CheckFailed        = $false
    UnresolvedSidCount = 0
    Error              = $null
  }
  try {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) {
      $acl = [System.IO.Directory]::GetAccessControl($Path)
    } else {
      $acl = [System.IO.File]::GetAccessControl($Path)
    }
    $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    $count = 0
    foreach ($r in $rules) {
      if ($r -and (-not $r.IsInherited) -and ($r.IdentityReference -is [System.Security.Principal.SecurityIdentifier])) {
        $sid = [System.Security.Principal.SecurityIdentifier]$r.IdentityReference
        if ($sid.Value -match '^S-1-5-') {
          try {
            [void]$sid.Translate([System.Security.Principal.NTAccount])
          } catch {
            $count++
          }
        }
      }
    }
    $result.UnresolvedSidCount = $count
    $result.HasRisk = ($count -gt 0)
  } catch {
    $result.HasRisk = $true
    $result.CheckFailed = $true
    $result.Error = $_.Exception.Message
  }
  return [pscustomobject]$result
}

function Get-RaymanRelativePath([string]$BasePath, [string]$TargetPath) {
  $baseNorm = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
  $targetNorm = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\') + '\'
  $baseUri = [System.Uri]::new($baseNorm)
  $targetUri = [System.Uri]::new($targetNorm)
  $relativeUri = $baseUri.MakeRelativeUri($targetUri)
  if ($relativeUri.ToString() -eq '') { return '' }
  return ([System.Uri]::UnescapeDataString($relativeUri.ToString()).TrimEnd('/') -replace '/', '\')
}

function Get-RaymanAncestorCandidates([string]$Path) {
  $candidates = New-Object System.Collections.Generic.List[string]
  $current = Split-Path -Path $Path -Parent
  while (-not [string]::IsNullOrWhiteSpace($current) -and $current -match '^[A-Za-z]:\\') {
    if (Test-Path -LiteralPath $current -PathType Container) {
      $candidates.Add(([System.IO.Path]::GetFullPath($current).TrimEnd('\'))) | Out-Null
    }
    $next = Split-Path -Path $current -Parent
    if ([string]::IsNullOrWhiteSpace($next) -or $next -eq $current) { break }
    $current = $next
  }
  return @($candidates | Select-Object -Unique)
}

function Get-RaymanSandboxMapping([string]$CurrentWorkspaceRoot) {
  $workspaceNorm = [System.IO.Path]::GetFullPath($CurrentWorkspaceRoot).TrimEnd('\')
  $workspaceAcl = Get-RaymanAclRiskInfo -Path $workspaceNorm
  $defaultMapping = [ordered]@{
    HostFolder   = $workspaceNorm
    SandboxFolder = 'C:\RaymanProject'
    ProjectRoot  = 'C:\RaymanProject'
    Bootstrap    = 'C:\RaymanProject\.Rayman\scripts\pwa\sandbox\bootstrap.ps1'
    MappingMode  = 'workspace-root'
    MappingReason = 'workspace-safe'
    WorkspaceAclRisk = $workspaceAcl
    HostAclRisk = $workspaceAcl
  }

  if (-not $workspaceAcl.HasRisk) {
    return $defaultMapping
  }

  $fallbacks = Get-RaymanAncestorCandidates -Path $workspaceNorm
  foreach ($candidate in $fallbacks) {
    $candidateAcl = Get-RaymanAclRiskInfo -Path $candidate
    if ($candidateAcl.HasRisk) { continue }

    $relative = Get-RaymanRelativePath -BasePath $candidate -TargetPath $workspaceNorm
    $projectRoot = 'C:\RaymanHost'
    if (-not [string]::IsNullOrWhiteSpace($relative)) {
      $projectRoot = ('C:\RaymanHost\{0}' -f $relative)
    }

    return [ordered]@{
      HostFolder   = $candidate
      SandboxFolder = 'C:\RaymanHost'
      ProjectRoot  = $projectRoot
      Bootstrap    = ('{0}\.Rayman\scripts\pwa\sandbox\bootstrap.ps1' -f $projectRoot)
      MappingMode  = 'ancestor-fallback'
      MappingReason = ('workspace_acl_risky;safe_ancestor={0}' -f $candidate)
      WorkspaceAclRisk = $workspaceAcl
      HostAclRisk = $candidateAcl
    }
  }

  $defaultMapping.MappingMode = 'workspace-root-risky'
  $defaultMapping.MappingReason = 'workspace_acl_risky;no_safe_ancestor_found'
  return $defaultMapping
}

$mapping = Get-RaymanSandboxMapping -CurrentWorkspaceRoot $WorkspaceRoot
$HostFolder = [string]$mapping.HostFolder
$SandboxFolder = [string]$mapping.SandboxFolder
$ProjectRoot = [string]$mapping.ProjectRoot
$Bootstrap = [string]$mapping.Bootstrap
$MappingMode = [string]$mapping.MappingMode
$MappingReason = [string]$mapping.MappingReason
$EscapedHostFolder = [System.Security.SecurityElement]::Escape($HostFolder)

if (-not (Test-Path -LiteralPath $HostFolder -PathType Container)) {
  throw "HostFolder 不存在：$HostFolder"
}
if ($HostFolder -notmatch '^[A-Za-z]:\\') {
  throw "HostFolder 必须是本地盘符绝对路径（当前：$HostFolder）"
}

$wsb = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$EscapedHostFolder</HostFolder>
      <SandboxFolder>$SandboxFolder</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell -NoProfile -ExecutionPolicy Bypass -File $Bootstrap</Command>
  </LogonCommand>
</Configuration>
"@

# NOTE:
# Windows PowerShell 5.1 的 `Out-File -Encoding utf8` 会写入 UTF-8 BOM，
# 在部分机器上会导致 Windows Sandbox 解析 .wsb 失败（常见报错 0x80070057 参数错误）。
# 这里显式写入 *无 BOM* 的 UTF-8。
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($WsbPath, $wsb, $utf8NoBom)

# Quick sanity checks: XML + required structure + path semantics.
try {
  [xml]$wsbXml = [System.IO.File]::ReadAllText($WsbPath)
} catch {
  throw "生成的 .wsb XML 不合法：$($_.Exception.Message)"
}

$hostFolder = [string]$wsbXml.Configuration.MappedFolders.MappedFolder.HostFolder
$sandboxFolder = [string]$wsbXml.Configuration.MappedFolders.MappedFolder.SandboxFolder
$command = [string]$wsbXml.Configuration.LogonCommand.Command

if (-not $hostFolder) {
  throw "生成的 .wsb 缺少 HostFolder。"
}
if ($hostFolder -notmatch '^[A-Za-z]:\\') {
  throw "HostFolder 必须是本地盘符绝对路径（当前：$hostFolder）"
}
if (-not (Test-Path -LiteralPath $hostFolder -PathType Container)) {
  throw "HostFolder 路径不存在：$hostFolder"
}
if (-not $sandboxFolder) {
  throw "生成的 .wsb 缺少 SandboxFolder。"
}
if ($sandboxFolder -notmatch '^[A-Za-z]:\\') {
  throw "SandboxFolder 必须是 Windows 绝对路径（当前：$sandboxFolder）"
}
if ($sandboxFolder -match '\\\\') {
  throw "SandboxFolder 不能包含双反斜杠（当前：$sandboxFolder）"
}
if ($command -match '-File\s+[A-Za-z]:\\\\') {
  throw "LogonCommand 中 -File 路径不能使用双反斜杠（当前：$command）"
}

Write-Host "[sandbox] wrote: $WsbPath (utf8-no-bom)"
Write-Host "[sandbox] mapping_mode: $MappingMode"
Write-Host "[sandbox] mapping_reason: $MappingReason"
Write-Host "[sandbox] host_folder: $HostFolder"
Write-Host "[sandbox] project_root_in_sandbox: $ProjectRoot"

$mappingPayload = [ordered]@{
  mappingMode       = $MappingMode
  mappingReason     = $MappingReason
  hostFolder        = $HostFolder
  sandboxFolder     = $SandboxFolder
  projectRoot       = $ProjectRoot
  bootstrap         = $Bootstrap
  workspaceAclRisk  = $mapping.WorkspaceAclRisk
  hostAclRisk       = $mapping.HostAclRisk
  generatedAt       = (Get-Date).ToString('o')
}
($mappingPayload | ConvertTo-Json -Depth 8) | Out-File -FilePath $MappingInfoPath -Encoding utf8
Write-Host "[sandbox] mapping_info: $MappingInfoPath"
