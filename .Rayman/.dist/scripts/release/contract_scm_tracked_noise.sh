#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ [rayman-contract-scm-noise] $*" >&2; exit 5; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COMMON="${ROOT}/.Rayman/common.ps1"
SETUP="${ROOT}/.Rayman/setup.ps1"
[[ -f "${COMMON}" ]] || fail "missing common.ps1: ${COMMON}"
[[ -f "${SETUP}" ]] || fail "missing setup.ps1: ${SETUP}"
command -v git >/dev/null 2>&1 || fail "git not found"

PS_HOST=""
if command -v powershell.exe >/dev/null 2>&1; then
  PS_HOST="$(command -v powershell.exe)"
elif command -v pwsh >/dev/null 2>&1; then
  PS_HOST="$(command -v pwsh)"
elif command -v powershell >/dev/null 2>&1; then
  PS_HOST="$(command -v powershell)"
else
  fail "pwsh/powershell not found"
fi

to_host_path() {
  local path="$1"
  if [[ "${PS_HOST,,}" == *"powershell.exe" ]]; then
    if command -v wslpath >/dev/null 2>&1; then
      wslpath -w "${path}"
      return 0
    fi
    if command -v cygpath >/dev/null 2>&1; then
      cygpath -w "${path}"
      return 0
    fi
  fi
  printf '%s' "${path}"
}

ps_script="$(mktemp)"
ps_output="$(mktemp)"
cleanup(){ rm -f "${ps_script}" "${ps_output}"; }
trap cleanup EXIT

cat > "${ps_script}" <<'PWSH'
param([string]$Root)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $Root '.Rayman/common.ps1')
$setupScript = Join-Path $Root '.Rayman/setup.ps1'

function Invoke-SetupContract {
  param([string]$WorkspaceRoot)

  $run = [ordered]@{
    ExitCode = 0
    Exception = ''
  }

  try {
    Remove-Item Env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS -ErrorAction SilentlyContinue
    Remove-Item Env:RAYMAN_SCM_IGNORE_MODE -ErrorAction SilentlyContinue
    $env:RAYMAN_PLAYWRIGHT_REQUIRE = '0'
    $env:RAYMAN_PLAYWRIGHT_AUTO_INSTALL = '0'
    $env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE = 'host'
    $env:RAYMAN_PLAYWRIGHT_TIMEOUT_SECONDS = '30'
    $env:RAYMAN_SKIP_PWA = '1'
    $env:RAYMAN_SETUP_GITHUB_LOGIN = '0'
    $env:RAYMAN_SETUP_SKIP_POST_CHECK = '1'
    $env:RAYMAN_SETUP_SKIP_ADVANCED_MODULES = '1'
    $env:RAYMAN_MCP_SQLITE_DB_AUTOFIX = '1'
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Global -Value 0 -Force } catch {}
    try { Set-Variable -Name 'LASTEXITCODE' -Scope Script -Value 0 -Force } catch {}
    & $setupScript -WorkspaceRoot $WorkspaceRoot -SkipReleaseGate *> $null
    if ($?) {
      $run.ExitCode = 0
    } elseif (Test-Path variable:LASTEXITCODE) {
      $run.ExitCode = [int]$LASTEXITCODE
    } else {
      $run.ExitCode = 1
    }
  } catch {
    $run.Exception = $_.Exception.Message
    if (Test-Path variable:LASTEXITCODE) {
      $run.ExitCode = [int]$LASTEXITCODE
    } else {
      $run.ExitCode = 1
    }
    if ($run.ExitCode -eq 0) { $run.ExitCode = 1 }
  }
  Remove-Item Env:RAYMAN_ALLOW_TRACKED_RAYMAN_ASSETS -ErrorAction SilentlyContinue
  Remove-Item Env:RAYMAN_SCM_IGNORE_MODE -ErrorAction SilentlyContinue

  return [pscustomobject]$run
}

function Get-LatestSetupLogPath([string]$WorkspaceRoot) {
  $logsDir = Join-Path (Join-Path $WorkspaceRoot '.Rayman') 'logs'
  if (-not (Test-Path -LiteralPath $logsDir -PathType Container)) { return '' }
  try {
    $latest = Get-ChildItem -LiteralPath $logsDir -Filter 'setup.win.*.log' -File -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($null -ne $latest) { return $latest.FullName }
  } catch {}
  return ''
}

function Write-ContractDiagLine([string]$Text) {
  [Console]::Error.WriteLine([string]$Text)
}

function Copy-RaymanTemplateForContract {
  param(
    [string]$SourceRayman,
    [string]$TargetRayman
  )

  if (-not (Test-Path -LiteralPath $SourceRayman -PathType Container)) {
    throw ("source .Rayman not found: {0}" -f $SourceRayman)
  }

  if (-not (Test-Path -LiteralPath $TargetRayman -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $TargetRayman | Out-Null
  }

  $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  [void]$excluded.Add('logs')
  [void]$excluded.Add('runtime')
  [void]$excluded.Add('state')
  [void]$excluded.Add('.Rayman')

  foreach ($entry in @(Get-ChildItem -LiteralPath $SourceRayman -Force -ErrorAction Stop)) {
    if ($excluded.Contains([string]$entry.Name)) { continue }
    Copy-Item -LiteralPath $entry.FullName -Destination $TargetRayman -Recurse -Force
  }
}

function New-TrackedNoiseWorkspace {
  param(
    [string]$Root,
    [ValidateSet('external', 'source')][string]$Mode
  )

  $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_contract_scm_noise_{0}_{1}' -f $Mode, [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

  Copy-RaymanTemplateForContract -SourceRayman (Join-Path $Root '.Rayman') -TargetRayman (Join-Path $tmpRoot '.Rayman')
  if ($Mode -eq 'source') {
    foreach ($workflowRel in @('.github/workflows/rayman-test-lanes.yml', '.github/workflows/rayman-nightly-smoke.yml')) {
      $src = Join-Path $Root $workflowRel
      if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
      $dst = Join-Path $tmpRoot $workflowRel
      $dstParent = Split-Path -Parent $dst
      if (-not (Test-Path -LiteralPath $dstParent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
      }
      Copy-Item -LiteralPath $src -Destination $dst -Force
    }
  }

  $tmpRaymanRoot = Join-Path $tmpRoot '.Rayman'
  foreach ($transientName in @('logs', 'runtime', 'state')) {
    $transientPath = Join-Path $tmpRaymanRoot $transientName
    if (Test-Path -LiteralPath $transientPath) {
      Remove-Item -LiteralPath $transientPath -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  foreach ($slowScriptRel in @(
    '.Rayman/scripts/memory/manage_memory.ps1',
    '.Rayman/scripts/mcp/manage_mcp.ps1',
    '.Rayman/scripts/agents/ensure_agent_capabilities.ps1'
  )) {
    $slowScriptPath = Join-Path $tmpRoot $slowScriptRel
    if (Test-Path -LiteralPath $slowScriptPath -PathType Leaf) {
      Remove-Item -LiteralPath $slowScriptPath -Force -ErrorAction SilentlyContinue
    }
  }

  git -C $tmpRoot init | Out-Null
  git -C $tmpRoot config user.name 'rayman-contract-scm-noise' | Out-Null
  git -C $tmpRoot config user.email 'rayman-contract-scm-noise@local' | Out-Null

  New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'src') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot '.dotnet10') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'dist') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'bin') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'obj') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot '.artifacts') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'test-results') | Out-Null
  $solutionDirName = if ($Mode -eq 'source') { '.RaymanContractSource' } else { '.RaymanContractExternal' }
  $solutionDirPath = Join-Path $tmpRoot $solutionDirName
  New-Item -ItemType Directory -Force -Path $solutionDirPath | Out-Null
  Set-Content -LiteralPath (Join-Path $tmpRoot 'src\Program.cs') -Value 'class Program {}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $tmpRoot '.dotnet10\cache.txt') -Value 'cache' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $tmpRoot 'dist\artifact.txt') -Value 'artifact' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $tmpRoot 'bin\output.dll') -Value 'bin' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $tmpRoot 'obj\output.dll') -Value 'obj' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $tmpRoot '.artifacts\report.json') -Value '{}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $tmpRoot 'test-results\result.xml') -Value '<tests />' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $solutionDirPath ($solutionDirName + '.requirements.md')) -Value '# contract requirements' -Encoding UTF8
  git -C $tmpRoot add -- 'src/Program.cs' '.dotnet10/cache.txt' 'dist/artifact.txt' | Out-Null

  return $tmpRoot
}

function Assert-BaseTrackedNoiseAnalysis {
  param([string]$WorkspaceRoot)

  $analysis = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $WorkspaceRoot
  if (-not $analysis.available -or -not $analysis.insideGit) {
    throw ("analysis unavailable: status={0}, reason={1}" -f [string]$analysis.status, [string]$analysis.reason)
  }
  if ($analysis.raymanBlocked) {
    throw 'analysis should not block when only advisory noisy dirs are tracked'
  }
  if (-not $analysis.advisoryPresent) {
    throw 'analysis should warn when advisory noisy dirs are tracked'
  }
  if ([int]$analysis.raymanTrackedCount -ne 0) {
    throw ("expected raymanTrackedCount=0, actual={0}" -f [int]$analysis.raymanTrackedCount)
  }
  if ([int]$analysis.advisoryTrackedCount -lt 2) {
    throw ("expected advisoryTrackedCount>=2, actual={0}" -f [int]$analysis.advisoryTrackedCount)
  }
  if ([string]$analysis.advisoryCommand -notmatch 'git rm -r --cached --') {
    throw ("unexpected advisory command: {0}" -f [string]$analysis.advisoryCommand)
  }
}

function Get-TrackedSolutionRequirementRelative([string]$WorkspaceRoot) {
  $candidate = Get-ChildItem -LiteralPath $WorkspaceRoot -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.StartsWith('.') } |
    ForEach-Object {
      $path = Join-Path $_.FullName ($_.Name + '.requirements.md')
      if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
    } |
    Select-Object -First 1

  if ($null -eq $candidate) {
    throw 'tracked solution requirements path not found'
  }

  return (Get-ContractRelativePath -BasePath $WorkspaceRoot -TargetPath ([string]$candidate))
}

function Get-GitCheckIgnoreResult {
  param(
    [string]$WorkspaceRoot,
    [string]$RelativePath
  )

  $rawOutput = @(& git -C $WorkspaceRoot check-ignore -v -- $RelativePath 2>&1)
  $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
  $matchedSource = ''
  $matchedPattern = ''
  $matchedPath = ''

  foreach ($line in @($rawOutput | ForEach-Object { [string]$_ })) {
    if ($line -match '^(?<source>.+?):(?<line>\d+):(?<pattern>[^\t]+)\t(?<path>.+)$') {
      $matchedSource = [string]$matches['source']
      $matchedPattern = [string]$matches['pattern']
      $matchedPath = [string]$matches['path']
      break
    }
  }

  return [pscustomobject]@{
    relative_path = $RelativePath
    ignored = ($exitCode -eq 0)
    exit_code = $exitCode
    matched_source = $matchedSource
    matched_pattern = $matchedPattern
    matched_path = $matchedPath
    raw_output = (@($rawOutput | ForEach-Object { [string]$_ }) -join "`n")
  }
}

function Get-ContractRelativePath {
  param(
    [string]$BasePath,
    [string]$TargetPath
  )

  $baseNorm = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
  $targetNorm = [System.IO.Path]::GetFullPath($TargetPath)
  if (Test-Path -LiteralPath $TargetPath -PathType Container) {
    $targetNorm = $targetNorm.TrimEnd('\') + '\'
  }

  $baseUri = [System.Uri]::new($baseNorm)
  $targetUri = [System.Uri]::new($targetNorm)
  $relativeUri = $baseUri.MakeRelativeUri($targetUri)
  if ([string]::IsNullOrWhiteSpace([string]$relativeUri)) {
    return ''
  }

  return [System.Uri]::UnescapeDataString($relativeUri.ToString()).TrimEnd('/')
}

function Get-TrackedSolutionAgenticDocRelativePaths {
  param(
    [string]$WorkspaceRoot,
    [string]$RequirementsPath = ''
  )

  if ([string]::IsNullOrWhiteSpace($RequirementsPath)) {
    $RequirementsPath = Get-TrackedSolutionRequirementRelative -WorkspaceRoot $WorkspaceRoot
  }

  $solutionDirRel = [System.IO.Path]::GetDirectoryName($RequirementsPath)
  if ([string]::IsNullOrWhiteSpace($solutionDirRel)) {
    throw ("unable to resolve solution dir from requirements path: {0}" -f $RequirementsPath)
  }

  $solutionDir = Join-Path $WorkspaceRoot ($solutionDirRel.Replace('/', '\'))
  $agenticDir = Join-Path $solutionDir 'agentic'
  New-Item -ItemType Directory -Force -Path $agenticDir | Out-Null

  $docs = [ordered]@{
    'contract-agentic.md' = "# agentic`n"
    'contract-agentic.json' = "{`"kind`":`"agentic`"}"
  }

  $result = New-Object System.Collections.Generic.List[string]
  foreach ($name in $docs.Keys) {
    $path = Join-Path $agenticDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      Set-Content -LiteralPath $path -Value $docs[$name] -Encoding UTF8
    }
    $result.Add((Get-ContractRelativePath -BasePath $WorkspaceRoot -TargetPath $path)) | Out-Null
  }

  return $result.ToArray()
}

function Get-ExternalBlockedTrackedTargets {
  param([string]$WorkspaceRoot)

  $targets = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @(
      '.Rayman/VERSION',
      '.SolutionName',
      '.cursorrules',
      '.clinerules',
      '.rayman.env.ps1',
      '.rayman.project.json',
      '.codex/config.toml',
      '.github/copilot-instructions.md',
      '.github/model-policy.md',
      '.github/workflows/rayman-project-fast-gate.yml',
      '.github/workflows/rayman-project-browser-gate.yml',
      '.github/workflows/rayman-project-full-gate.yml',
      '.vscode/tasks.json',
      '.vscode/settings.json',
      '.vscode/launch.json'
    )) {
    if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot $candidate)) {
      $targets.Add($candidate) | Out-Null
    }
  }

  foreach ($dirRel in @('.github/instructions', '.github/agents', '.github/skills', '.github/prompts')) {
    $dirPath = Join-Path $WorkspaceRoot $dirRel
    if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { continue }
    $sample = Get-ChildItem -LiteralPath $dirPath -Recurse -File -ErrorAction SilentlyContinue |
      Sort-Object FullName |
      Select-Object -First 1
    if ($null -eq $sample) { continue }
    $targets.Add((Get-ContractRelativePath -BasePath $WorkspaceRoot -TargetPath ([string]$sample.FullName))) | Out-Null
  }

  return @($targets | Select-Object -Unique)
}

function Get-ManagedIgnorePath {
  param([string]$WorkspaceRoot)

  $workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
  $defaultMode = if ($workspaceKind -eq 'external') { 'gitignore' } else { 'info-exclude' }
  $rawMode = [string][Environment]::GetEnvironmentVariable('RAYMAN_SCM_IGNORE_MODE')
  $mode = if ([string]::IsNullOrWhiteSpace($rawMode)) { $defaultMode } else { $rawMode.Trim().ToLowerInvariant() }
  $preferredPath = ''
  $fallbackPath = ''

  switch ($mode) {
    'gitignore' {
      $preferredPath = Join-Path $WorkspaceRoot '.gitignore'
      $fallbackPath = Join-Path $WorkspaceRoot '.git\info\exclude'
      break
    }
    'info-exclude' {
      $preferredPath = Join-Path $WorkspaceRoot '.git\info\exclude'
      $fallbackPath = Join-Path $WorkspaceRoot '.gitignore'
      break
    }
    default { throw ("unsupported managed ignore mode for contract: {0}" -f $mode) }
  }

  foreach ($candidate in @($preferredPath, $fallbackPath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $raw = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($raw -match '# RAYMAN:GENERATED:BEGIN' -and $raw -match '# RAYMAN:GENERATED:END') {
      return $candidate
    }
  }

  if (Test-Path -LiteralPath $preferredPath -PathType Leaf) { return $preferredPath }
  if (Test-Path -LiteralPath $fallbackPath -PathType Leaf) { return $fallbackPath }
  return $preferredPath
}

function Get-ManagedIgnoreSummary {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @()
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

  $lines = @($raw -split "`r?`n")
  $beginIndex = -1
  $endIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '# RAYMAN:GENERATED:BEGIN') { $beginIndex = $i; continue }
    if ($lines[$i] -match '# RAYMAN:GENERATED:END') { $endIndex = $i; break }
  }

  if ($beginIndex -ge 0 -and $endIndex -ge $beginIndex) {
    return @($lines[$beginIndex..$endIndex] | Select-Object -First 14)
  }

  return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 14)
}

function Get-ContractDiagnosticEntry {
  param([string]$Mode)

  if (-not $script:ContractDiagnostics.Contains($Mode)) {
    $script:ContractDiagnostics[$Mode] = [ordered]@{
      mode = $Mode
      workspace_root = ''
      workspace_kind = ''
      managed_ignore_path = ''
      managed_ignore_summary = @()
      blocked_targets = @()
      check_ignore_results = @()
      latest_setup_log = ''
    }
  }

  return $script:ContractDiagnostics[$Mode]
}

function Update-ContractWorkspaceSnapshot {
  param(
    [string]$Mode,
    [string]$WorkspaceRoot,
    [string[]]$BlockedTargets = @()
  )

  $entry = Get-ContractDiagnosticEntry -Mode $Mode
  $entry.workspace_root = $WorkspaceRoot
  try { $entry.workspace_kind = [string](Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot) } catch {}
  try { $entry.managed_ignore_path = [string](Get-ManagedIgnorePath -WorkspaceRoot $WorkspaceRoot) } catch {}
  $entry.managed_ignore_summary = @(Get-ManagedIgnoreSummary -Path ([string]$entry.managed_ignore_path))
  $entry.blocked_targets = @($BlockedTargets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $entry.latest_setup_log = [string](Get-LatestSetupLogPath -WorkspaceRoot $WorkspaceRoot)
}

function Add-ContractCheckIgnoreResult {
  param(
    [string]$Mode,
    [object]$Result
  )

  if ($null -eq $Result) { return }
  $entry = Get-ContractDiagnosticEntry -Mode $Mode
  $entry.check_ignore_results = @($entry.check_ignore_results) + @([pscustomobject]@{
      relative_path = [string]$Result.relative_path
      ignored = [bool]$Result.ignored
      exit_code = [int]$Result.exit_code
      matched_source = [string]$Result.matched_source
      matched_pattern = [string]$Result.matched_pattern
      matched_path = [string]$Result.matched_path
      raw_output = [string]$Result.raw_output
    })
}

function Resolve-ContractPathUnderWorkspace {
  param(
    [string]$WorkspaceRoot,
    [string]$CandidatePath
  )

  if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return '' }
  if ([System.IO.Path]::IsPathRooted($CandidatePath)) { return $CandidatePath }
  return (Join-Path $WorkspaceRoot ($CandidatePath.Replace('/', '\')))
}

function Test-RaymanManagedIgnoreFile {
  param(
    [string]$WorkspaceRoot,
    [string]$MatchedSource
  )

  $path = Resolve-ContractPathUnderWorkspace -WorkspaceRoot $WorkspaceRoot -CandidatePath $MatchedSource
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $false
  }

  $leaf = [string](Split-Path -Leaf $path)
  if ($leaf -ne '.gitignore' -and $leaf -ne 'exclude') {
    return $false
  }

  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  return ($raw -match '# RAYMAN:GENERATED:BEGIN' -and $raw -match '# RAYMAN:GENERATED:END')
}

function Write-ContractDiagnostics {
  if ($null -eq $script:ContractDiagnostics -or $script:ContractDiagnostics.Count -eq 0) { return }

  Write-ContractDiagLine '[diag] scm tracked noise contract failure context:'
  foreach ($mode in @($script:ContractDiagnostics.Keys)) {
    $entry = $script:ContractDiagnostics[$mode]
    if ($null -eq $entry) { continue }

    Write-ContractDiagLine ("[diag][{0}] workspace_root={1}" -f $mode, [string]$entry.workspace_root)
    Write-ContractDiagLine ("[diag][{0}] workspace_kind={1}" -f $mode, [string]$entry.workspace_kind)
    Write-ContractDiagLine ("[diag][{0}] managed_ignore_path={1}" -f $mode, [string]$entry.managed_ignore_path)
    Write-ContractDiagLine ("[diag][{0}] latest_setup_log={1}" -f $mode, [string]$entry.latest_setup_log)
    Write-ContractDiagLine ("[diag][{0}] blocked_targets={1}" -f $mode, ((@($entry.blocked_targets) | ForEach-Object { [string]$_ }) -join ', '))

    foreach ($line in @($entry.managed_ignore_summary | ForEach-Object { [string]$_ })) {
      Write-ContractDiagLine ("[diag][{0}][managed-ignore] {1}" -f $mode, $line)
    }

    foreach ($result in @($entry.check_ignore_results)) {
      Write-ContractDiagLine ("[diag][{0}][check-ignore] target={1} ignored={2} exit={3} source={4} pattern={5}" -f
        $mode,
        [string]$result.relative_path,
        [bool]$result.ignored,
        [int]$result.exit_code,
        [string]$result.matched_source,
        [string]$result.matched_pattern)
      if (-not [string]::IsNullOrWhiteSpace([string]$result.raw_output)) {
        Write-ContractDiagLine ("[diag][{0}][check-ignore-raw] {1}" -f $mode, ([string]$result.raw_output -replace "`r?`n", ' | '))
      }
    }
  }
}

function Assert-ManagedIgnoreBlock {
  param([string]$WorkspaceRoot)

  $managedIgnorePath = Get-ManagedIgnorePath -WorkspaceRoot $WorkspaceRoot
  if (-not (Test-Path -LiteralPath $managedIgnorePath -PathType Leaf)) {
    throw ("managed ignore file missing: {0}" -f $managedIgnorePath)
  }

  $raw = Get-Content -LiteralPath $managedIgnorePath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw ("managed ignore file is empty: {0}" -f $managedIgnorePath)
  }
}

function Assert-ExternalAllowedDocsTrackable {
  param([string]$WorkspaceRoot)

  $requirementsPath = Get-TrackedSolutionRequirementRelative -WorkspaceRoot $WorkspaceRoot
  $docTargets = @($requirementsPath) + @(Get-TrackedSolutionAgenticDocRelativePaths -WorkspaceRoot $WorkspaceRoot -RequirementsPath $requirementsPath)

  foreach ($docTarget in @($docTargets | Select-Object -Unique)) {
    $result = Get-GitCheckIgnoreResult -WorkspaceRoot $WorkspaceRoot -RelativePath $docTarget
    Add-ContractCheckIgnoreResult -Mode 'external' -Result $result
    if ([bool]$result.ignored) {
      throw ("external workspace should keep doc trackable: {0}" -f $docTarget)
    }
  }
}

function Assert-ExternalBlockedTargetsIgnored {
  param([string]$WorkspaceRoot)

  $blockedTargets = @(Get-ExternalBlockedTrackedTargets -WorkspaceRoot $WorkspaceRoot)
  $requiredGeneratedTargets = @(@(
    '.rayman.project.json',
    '.github/workflows/rayman-project-fast-gate.yml',
    '.github/workflows/rayman-project-browser-gate.yml',
    '.github/workflows/rayman-project-full-gate.yml'
  ) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot $_)) })
  Update-ContractWorkspaceSnapshot -Mode 'external' -WorkspaceRoot $WorkspaceRoot -BlockedTargets $blockedTargets

  if ($blockedTargets.Count -le 0) {
    throw 'external setup did not generate expected Rayman workflow/config assets'
  }
  if ($requiredGeneratedTargets.Count -gt 0) {
    throw ("external setup missing expected generated assets: {0}" -f ($requiredGeneratedTargets -join ', '))
  }

  foreach ($ignoredPath in @($blockedTargets)) {
    $result = Get-GitCheckIgnoreResult -WorkspaceRoot $WorkspaceRoot -RelativePath $ignoredPath
    Add-ContractCheckIgnoreResult -Mode 'external' -Result $result

    if (-not [bool]$result.ignored) {
      throw ("external workspace should ignore generated Rayman asset: {0}" -f $ignoredPath)
    }
    if (-not (Test-RaymanManagedIgnoreFile -WorkspaceRoot $WorkspaceRoot -MatchedSource ([string]$result.matched_source))) {
      throw ("external workspace ignore for {0} did not come from a Rayman managed block: {1}" -f $ignoredPath, [string]$result.matched_source)
    }
  }
}

function Assert-SourceManagedIgnoreBlockDoesNotHideAuthoredRaymanDirectories {
  param([string]$WorkspaceRoot)

  $managedIgnorePath = Get-ManagedIgnorePath -WorkspaceRoot $WorkspaceRoot
  if (-not (Test-Path -LiteralPath $managedIgnorePath -PathType Leaf)) {
    throw ("managed ignore file missing: {0}" -f $managedIgnorePath)
  }

  $raw = Get-Content -LiteralPath $managedIgnorePath -Raw -Encoding UTF8

  foreach ($rule in @('.Rayman/.dist/', '.Rayman/scripts/')) {
    if ($raw -match ('(?m)^\s*' + [regex]::Escape($rule) + '\s*$')) {
      throw ("source workspace managed ignore block must not hide authored path: {0}" -f $rule)
    }
  }
}

function Get-SourceAllowedTrackedTargets([string]$WorkspaceRoot) {
  return @(
    '.Rayman/VERSION',
    '.Rayman/.dist/VERSION',
    '.SolutionName'
  ) | Where-Object { Test-Path -LiteralPath (Join-Path $WorkspaceRoot $_) }
}

function Get-SourceBlockedTrackedTargets([string]$WorkspaceRoot) {
  return @(
    '.Rayman/context/skills.auto.md',
    '.rayman.env.ps1',
    '.cursorrules',
    '.clinerules',
    '.vscode/tasks.json',
    '.vscode/settings.json',
    '.vscode/launch.json'
  ) | Where-Object { Test-Path -LiteralPath (Join-Path $WorkspaceRoot $_) }
}

function Assert-SourceBlockedTargetsIgnored {
  param([string]$WorkspaceRoot)

  $blockedTargets = @(Get-SourceBlockedTrackedTargets -WorkspaceRoot $WorkspaceRoot)
  Update-ContractWorkspaceSnapshot -Mode 'source' -WorkspaceRoot $WorkspaceRoot -BlockedTargets $blockedTargets

  foreach ($ignoredPath in @($blockedTargets)) {
    $result = Get-GitCheckIgnoreResult -WorkspaceRoot $WorkspaceRoot -RelativePath $ignoredPath
    Add-ContractCheckIgnoreResult -Mode 'source' -Result $result

    if (-not [bool]$result.ignored) {
      throw ("source workspace should ignore local/generated asset: {0}" -f $ignoredPath)
    }
    if (-not (Test-RaymanManagedIgnoreFile -WorkspaceRoot $WorkspaceRoot -MatchedSource ([string]$result.matched_source))) {
      throw ("source workspace ignore for {0} did not come from a Rayman managed block: {1}" -f $ignoredPath, [string]$result.matched_source)
    }
  }
}

$script:ContractDiagnostics = [ordered]@{}
$externalRoot = ''
$sourceRoot = ''

try {
  $externalRoot = New-TrackedNoiseWorkspace -Root $Root -Mode 'external'
  Update-ContractWorkspaceSnapshot -Mode 'external' -WorkspaceRoot $externalRoot
  if ((Get-RaymanWorkspaceKind -WorkspaceRoot $externalRoot) -ne 'external') {
    throw 'external workspace should classify as external'
  }
  Assert-BaseTrackedNoiseAnalysis -WorkspaceRoot $externalRoot

  $firstRun = Invoke-SetupContract -WorkspaceRoot $externalRoot
  Update-ContractWorkspaceSnapshot -Mode 'external' -WorkspaceRoot $externalRoot
  if ($firstRun.ExitCode -ne 0) {
    throw ("external first setup run should pass, exit={0}, exception={1}" -f $firstRun.ExitCode, [string]$firstRun.Exception)
  }

  Assert-ManagedIgnoreBlock -WorkspaceRoot $externalRoot
  Assert-ExternalAllowedDocsTrackable -WorkspaceRoot $externalRoot
  Assert-ExternalBlockedTargetsIgnored -WorkspaceRoot $externalRoot

  $sourceRoot = New-TrackedNoiseWorkspace -Root $Root -Mode 'source'
  Update-ContractWorkspaceSnapshot -Mode 'source' -WorkspaceRoot $sourceRoot
  if ((Get-RaymanWorkspaceKind -WorkspaceRoot $sourceRoot) -ne 'source') {
    throw 'source workspace should classify as source'
  }
  Assert-BaseTrackedNoiseAnalysis -WorkspaceRoot $sourceRoot

  $firstRun = Invoke-SetupContract -WorkspaceRoot $sourceRoot
  Update-ContractWorkspaceSnapshot -Mode 'source' -WorkspaceRoot $sourceRoot
  if ($firstRun.ExitCode -ne 0) {
    throw ("source first setup run should pass, exit={0}, exception={1}" -f $firstRun.ExitCode, [string]$firstRun.Exception)
  }
  Assert-SourceManagedIgnoreBlockDoesNotHideAuthoredRaymanDirectories -WorkspaceRoot $sourceRoot
  Assert-SourceBlockedTargetsIgnored -WorkspaceRoot $sourceRoot

  $allowedTargets = @(Get-SourceAllowedTrackedTargets -WorkspaceRoot $sourceRoot)
  if ($allowedTargets.Count -le 0) {
    throw 'source setup did not generate expected authored Rayman assets'
  }
  git -C $sourceRoot add -f -- @($allowedTargets) | Out-Null

  $allowedAnalysis = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $sourceRoot
  if ($allowedAnalysis.raymanBlocked) {
    throw 'analysis should allow authored .Rayman and .SolutionName in source workspace'
  }
  if ([int]$allowedAnalysis.raymanTrackedCount -ne 0) {
    throw ("expected raymanTrackedCount=0 for authored source assets, actual={0}" -f [int]$allowedAnalysis.raymanTrackedCount)
  }

  $allowedRun = Invoke-SetupContract -WorkspaceRoot $sourceRoot
  Update-ContractWorkspaceSnapshot -Mode 'source' -WorkspaceRoot $sourceRoot -BlockedTargets @(Get-SourceBlockedTrackedTargets -WorkspaceRoot $sourceRoot)
  if ($allowedRun.ExitCode -ne 0) {
    throw ("source workspace should keep passing when only authored assets are tracked, exit={0}, exception={1}" -f $allowedRun.ExitCode, [string]$allowedRun.Exception)
  }

  $blockedTargets = @(Get-SourceBlockedTrackedTargets -WorkspaceRoot $sourceRoot)
  if ($blockedTargets.Count -le 0) {
    throw 'source setup did not generate expected local/generated assets'
  }
  git -C $sourceRoot add -f -- @($blockedTargets) | Out-Null

  $blockedAnalysis = Get-RaymanScmTrackedNoiseAnalysis -WorkspaceRoot $sourceRoot
  if (-not $blockedAnalysis.raymanBlocked) {
    throw 'analysis should block when local/generated Rayman assets are present in source workspace'
  }
  if ([string]$blockedAnalysis.raymanCommand -notmatch '\.rayman\.env\.ps1|\.cursorrules|\.clinerules|\.vscode') {
    throw ("unexpected rayman command: {0}" -f [string]$blockedAnalysis.raymanCommand)
  }

  $blockedRun = Invoke-SetupContract -WorkspaceRoot $sourceRoot
  Update-ContractWorkspaceSnapshot -Mode 'source' -WorkspaceRoot $sourceRoot -BlockedTargets $blockedTargets
  if ($blockedRun.ExitCode -eq 0) {
    throw 'source workspace setup should fail when tracked local/generated assets are present without allow marker'
  }
  $blockedLog = Get-LatestSetupLogPath -WorkspaceRoot $sourceRoot
  if ([string]::IsNullOrWhiteSpace($blockedLog) -or -not (Select-String -LiteralPath $blockedLog -Pattern 'tracked_rayman_assets_blocked' -Quiet)) {
    throw ("source blocked setup log missing tracked marker: {0}" -f $blockedLog)
  }
  Write-Output 'OK'
} catch {
  Write-ContractDiagnostics
  throw
} finally {
  try { if (-not [string]::IsNullOrWhiteSpace($externalRoot)) { Remove-Item -LiteralPath $externalRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
  try { Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
PWSH

ps_script_host="$(to_host_path "${ps_script}")"
root_host="$(to_host_path "${ROOT}")"

"${PS_HOST}" -NoProfile -ExecutionPolicy Bypass -File "${ps_script_host}" -Root "${root_host}" >"${ps_output}" 2>&1 || {
  [[ -s "${ps_output}" ]] && cat "${ps_output}" >&2
  exit 5
}
echo "OK"
