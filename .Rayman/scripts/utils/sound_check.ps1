param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [ValidateSet('both', 'manual', 'done')][string]$Mode = 'both',
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}

function Get-RaymanSoundCheckPaths {
  param([string]$WorkspaceRoot)

  $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
  $runtimeDir = Join-Path $resolvedRoot '.Rayman\runtime'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  return [pscustomobject]@{
    workspace_root = $resolvedRoot
    runtime_dir = $runtimeDir
    json_path = (Join-Path $runtimeDir 'sound_check.last.json')
    markdown_path = (Join-Path $runtimeDir 'sound_check.last.md')
  }
}

function Write-RaymanSoundCheckJson {
  param(
    [string]$Path,
    [object]$Value
  )

  $json = ($Value | ConvertTo-Json -Depth 8)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Write-RaymanSoundCheckMarkdown {
  param(
    [string]$Path,
    [object]$Report
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Rayman Sound Check') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- generated_at: {0}' -f [string]$Report.generated_at)) | Out-Null
  $lines.Add(('- result: {0}' -f [string]$Report.result)) | Out-Null
  $lines.Add(('- sound_path: {0}' -f [string]$Report.sound_path)) | Out-Null
  $lines.Add(('- sound_path_exists: {0}' -f [string]([bool]$Report.sound_path_exists).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add(('- manual_enabled: {0}' -f [string]([bool]$Report.manual_enabled).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add(('- done_enabled: {0}' -f [string]([bool]$Report.done_enabled).ToString().ToLowerInvariant())) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('## Steps') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($step in @($Report.steps)) {
    $lines.Add(('- {0}: entrypoint={1} result={2} confirmed={3}' -f [string]$step.kind, [string]$step.entrypoint, [string]$step.result, [string]$step.user_confirmed)) | Out-Null
  }
  if (@($Report.windows_sound_devices).Count -gt 0) {
    $lines.Add('') | Out-Null
    $lines.Add('## Windows Sound Devices') | Out-Null
    $lines.Add('') | Out-Null
    foreach ($device in @($Report.windows_sound_devices)) {
      $lines.Add(('- {0} | status={1} | manufacturer={2}' -f [string]$device.name, [string]$device.status, [string]$device.manufacturer)) | Out-Null
    }
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, (($lines -join "`r`n").TrimEnd() + "`r`n"), $utf8NoBom)
}

function Get-RaymanSoundCheckWindowsDevices {
  if (-not (Get-Command Test-RaymanWindowsPlatform -ErrorAction SilentlyContinue) -or -not (Test-RaymanWindowsPlatform)) {
    return @()
  }

  try {
    return @(
      Get-CimInstance Win32_SoundDevice -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
          name = [string]$_.Name
          status = [string]$_.Status
          manufacturer = [string]$_.Manufacturer
          pnp_device_id = [string]$_.PNPDeviceID
        }
      }
    )
  } catch {
    return @()
  }
}

function Read-RaymanSoundCheckConfirmation {
  param([string]$Kind)

  while ($true) {
    $answer = [string](Read-Host ("[{0}] 听到了吗？输入 1=听到了 / 2=没听到 / q=取消" -f $Kind))
    switch ($answer.Trim().ToLowerInvariant()) {
      '1' { return 'heard' }
      '2' { return 'not_heard' }
      'q' { return 'cancelled' }
      'quit' { return 'cancelled' }
      'exit' { return 'cancelled' }
      default {
        Write-Host '[sound-check] 请输入 1、2 或 q。' -ForegroundColor Yellow
      }
    }
  }
}

function Invoke-RaymanSoundCheckManualEntrypoint {
  param([string]$WorkspaceRoot)

  $scriptPath = Join-Path $WorkspaceRoot '.Rayman\scripts\utils\request_attention.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "request_attention.ps1 not found: $scriptPath"
  }

  & $scriptPath -Kind manual -Title 'Rayman 声音自检（人工提醒）' -Message '请确认你是否听到了这次人工提醒音。' -WorkspaceRoot $WorkspaceRoot | Out-Null
}

function Invoke-RaymanSoundCheckDoneEntrypoint {
  param([string]$WorkspaceRoot)

  $scriptPath = Join-Path $WorkspaceRoot '.Rayman\scripts\codex\codex_notify.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "codex_notify.ps1 not found: $scriptPath"
  }

  $payload = '{"type":"agent-turn-complete"}'
  & $scriptPath -WorkspaceRoot $WorkspaceRoot ignored $payload | Out-Null
}

function Invoke-RaymanSoundCheckStep {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('manual', 'done')][string]$Kind,
    [string]$SoundPath
  )

  $enabled = Get-RaymanAttentionSoundEnabled -WorkspaceRoot $WorkspaceRoot -Kind $Kind
  $pathExists = (-not [string]::IsNullOrWhiteSpace([string]$SoundPath) -and (Test-Path -LiteralPath $SoundPath -PathType Leaf))
  $entrypoint = if ($Kind -eq 'manual') { 'request_attention.ps1' } else { 'codex_notify.ps1' }

  $step = [ordered]@{
    kind = $Kind
    entrypoint = $entrypoint
    playback_invoked = $false
    user_confirmed = 'not_asked'
    result = 'failed'
    error = ''
  }

  if (-not $enabled) {
    $step.error = ('{0}_sound_disabled' -f $Kind)
    return [pscustomobject]$step
  }
  if (-not $pathExists) {
    $step.error = 'sound_path_missing'
    return [pscustomobject]$step
  }

  try {
    if ($Kind -eq 'manual') {
      Invoke-RaymanSoundCheckManualEntrypoint -WorkspaceRoot $WorkspaceRoot
    } else {
      Invoke-RaymanSoundCheckDoneEntrypoint -WorkspaceRoot $WorkspaceRoot
    }
    $step.playback_invoked = $true
  } catch {
    $step.error = $_.Exception.Message
    return [pscustomobject]$step
  }

  $confirmation = Read-RaymanSoundCheckConfirmation -Kind $Kind
  $step.user_confirmed = $confirmation
  switch ($confirmation) {
    'heard' { $step.result = 'passed' }
    'cancelled' { $step.result = 'cancelled' }
    default { $step.result = 'failed' }
  }

  return [pscustomobject]$step
}

function Invoke-RaymanSoundCheck {
  param(
    [string]$WorkspaceRoot,
    [ValidateSet('both', 'manual', 'done')][string]$Mode = 'both'
  )

  $paths = Get-RaymanSoundCheckPaths -WorkspaceRoot $WorkspaceRoot
  $resolvedRoot = [string]$paths.workspace_root
  $soundPath = [string](Get-RaymanAttentionSoundPath -WorkspaceRoot $resolvedRoot)
  $manualEnabled = [bool](Get-RaymanAttentionSoundEnabled -WorkspaceRoot $resolvedRoot -Kind 'manual')
  $doneEnabled = [bool](Get-RaymanAttentionSoundEnabled -WorkspaceRoot $resolvedRoot -Kind 'done')
  $soundPathExists = (-not [string]::IsNullOrWhiteSpace($soundPath) -and (Test-Path -LiteralPath $soundPath -PathType Leaf))
  $windowsDevices = @(
    Get-RaymanSoundCheckWindowsDevices
  )

  $report = [ordered]@{
    schema = 'rayman.sound_check.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $resolvedRoot
    sound_path = $soundPath
    sound_path_exists = $soundPathExists
    manual_enabled = $manualEnabled
    done_enabled = $doneEnabled
    windows_sound_devices = @($windowsDevices)
    steps = @()
    result = 'unsupported'
  }

  if (-not (Get-Command Test-RaymanWindowsPlatform -ErrorAction SilentlyContinue) -or -not (Test-RaymanWindowsPlatform)) {
    Write-RaymanSoundCheckJson -Path $paths.json_path -Value $report
    Write-RaymanSoundCheckMarkdown -Path $paths.markdown_path -Report $report
    return [pscustomobject]$report
  }

  $kinds = switch ($Mode) {
    'manual' { @('manual') }
    'done' { @('done') }
    default { @('manual', 'done') }
  }

  $steps = New-Object System.Collections.Generic.List[object]
  $finalResult = 'passed'
  foreach ($kind in $kinds) {
    $step = Invoke-RaymanSoundCheckStep -WorkspaceRoot $resolvedRoot -Kind $kind -SoundPath $soundPath
    $steps.Add($step) | Out-Null
    switch ([string]$step.result) {
      'cancelled' {
        $finalResult = 'cancelled'
        break
      }
      'failed' {
        if ($finalResult -ne 'cancelled') {
          $finalResult = 'failed'
        }
      }
    }
    if ($finalResult -eq 'cancelled') {
      break
    }
  }

  $report.steps = @($steps.ToArray())
  $report.result = $finalResult
  Write-RaymanSoundCheckJson -Path $paths.json_path -Value $report
  Write-RaymanSoundCheckMarkdown -Path $paths.markdown_path -Report $report
  return [pscustomobject]$report
}

if ($NoMain) {
  return
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$report = Invoke-RaymanSoundCheck -WorkspaceRoot $WorkspaceRoot -Mode $Mode

Write-Host ("[sound-check] result={0}" -f [string]$report.result) -ForegroundColor Cyan
Write-Host ("[sound-check] report={0}" -f (Join-Path $WorkspaceRoot '.Rayman\runtime\sound_check.last.json')) -ForegroundColor DarkCyan

switch ([string]$report.result) {
  'passed' { exit 0 }
  'failed' { exit 1 }
  default { exit 2 }
}
