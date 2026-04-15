param(
  [ValidateSet('manual', 'done', 'error')][string]$Kind = 'manual',
  [string]$Message = 'Rayman 需要您关注当前任务。',
  [string]$Title = 'Rayman 提醒',
  [string]$WorkspaceRoot = '',
  [switch]$EnableSpeech,
  [switch]$DisableSpeech,
  [switch]$DisableSound
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}

function Get-AttentionWorkspaceRoot {
  if (Get-Command Resolve-RaymanWorkspaceRoot -ErrorAction SilentlyContinue) {
    try { return (Resolve-RaymanWorkspaceRoot) } catch {}
  }

  try {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
  } catch {
    return ''
  }
}

function Resolve-AttentionWorkspaceRoot {
  param([string]$WorkspaceRoot)

  if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    if (Get-Command Get-RaymanAttentionWorkspaceRoot -ErrorAction SilentlyContinue) {
      try { return (Get-RaymanAttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot) } catch {}
    }
    try { return (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).Path } catch {}
  }

  return (Get-AttentionWorkspaceRoot)
}

function Escape-ToastXml([string]$Value) {
  if ($null -eq $Value) { return '' }
  return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-WindowsToastManagerType {
  foreach ($typeName in @(
    'Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime',
    'Windows.UI.Notifications.ToastNotificationManager, Windows, ContentType = WindowsRuntime'
  )) {
    try {
      $resolved = $typeName -as [type]
      if ($null -ne $resolved) {
        return $resolved
      }
    } catch {}
  }

  return $null
}

function Test-WindowsToastSupported {
  if ($env:OS -ne 'Windows_NT') { return $false }
  $managerType = Get-WindowsToastManagerType
  if ($null -eq $managerType) { return $false }
  try {
    $null = New-Object Windows.Data.Xml.Dom.XmlDocument
    return $true
  } catch {
    return $false
  }
}

function Show-WindowsToast([string]$ToastTitle, [string]$ToastMessage) {
  if (-not (Test-WindowsToastSupported)) {
    return $false
  }

  try {
    $xml = @"
<toast>
  <visual>
    <binding template="ToastText02">
      <text id="1">$(Escape-ToastXml $ToastTitle)</text>
      <text id="2">$(Escape-ToastXml $ToastMessage)</text>
    </binding>
  </visual>
</toast>
"@
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Rayman AI').Show($toast)
    return $true
  } catch {
    return $false
  }
}

function Invoke-AttentionSpeech([string]$SpeechText) {
  try {
    $speaker = New-Object -ComObject SAPI.SpVoice
    [void]$speaker.Speak($SpeechText)
  } catch {}
}

function Test-AttentionNotificationEnabled {
  param(
    [string]$Kind,
    [string]$WorkspaceRoot
  )

  if (Get-Command Get-RaymanAttentionAlertEnabled -ErrorAction SilentlyContinue) {
    try {
      return (Get-RaymanAttentionAlertEnabled -WorkspaceRoot $WorkspaceRoot -Kind $Kind)
    } catch {}
  }

  return $true
}

function Resolve-AttentionSurface {
  param([string]$WorkspaceRoot)

  if (Get-Command Get-RaymanAttentionSurface -ErrorAction SilentlyContinue) {
    try { return (Get-RaymanAttentionSurface -WorkspaceRoot $WorkspaceRoot -Default 'log') } catch {}
  }

  return 'log'
}

function Write-AttentionStateRecord {
  param(
    [string]$WorkspaceRoot,
    [string]$Kind,
    [string]$Title,
    [string]$Message,
    [string]$Surface,
    [bool]$AlertEnabled,
    [bool]$SpeechEnabled,
    [bool]$Suppressed
  )

  if (Get-Command Write-RaymanAttentionState -ErrorAction SilentlyContinue) {
    try {
      Write-RaymanAttentionState -WorkspaceRoot $WorkspaceRoot -Kind $Kind -Title $Title -Message $Message -Surface $Surface -AlertEnabled $AlertEnabled -SpeechEnabled $SpeechEnabled -Suppressed $Suppressed
      return
    } catch {}
  }
}

function Resolve-AttentionSpeechEnabled {
  param(
    [string]$Kind,
    [string]$WorkspaceRoot,
    [switch]$EnableSpeech,
    [switch]$DisableSpeech
  )

  if ($PSBoundParameters.ContainsKey('EnableSpeech')) {
    return [bool]$EnableSpeech.IsPresent
  }
  if ($PSBoundParameters.ContainsKey('DisableSpeech')) {
    return (-not [bool]$DisableSpeech.IsPresent)
  }

  if (Get-Command Get-RaymanAttentionSpeechEnabled -ErrorAction SilentlyContinue) {
    try {
      return (Get-RaymanAttentionSpeechEnabled -WorkspaceRoot $WorkspaceRoot -Kind $Kind)
    } catch {}
  }

  return $true
}

function Resolve-AttentionSoundEnabled {
  param(
    [string]$Kind,
    [string]$WorkspaceRoot,
    [switch]$DisableSound
  )

  if ($PSBoundParameters.ContainsKey('DisableSound') -and [bool]$DisableSound.IsPresent) {
    return $false
  }

  if (Get-Command Get-RaymanAttentionSoundEnabled -ErrorAction SilentlyContinue) {
    try {
      return (Get-RaymanAttentionSoundEnabled -WorkspaceRoot $WorkspaceRoot -Kind $Kind)
    } catch {}
  }

  return $false
}

function Resolve-AttentionSoundPath {
  param([string]$WorkspaceRoot)

  if (Get-Command Get-RaymanAttentionSoundPath -ErrorAction SilentlyContinue) {
    try {
      return (Get-RaymanAttentionSoundPath -WorkspaceRoot $WorkspaceRoot)
    } catch {}
  }

  if ($env:OS -ne 'Windows_NT') {
    return ''
  }
  return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\notify.wav')
}

function Invoke-AttentionSound([string]$SoundPath) {
  if ([string]::IsNullOrWhiteSpace([string]$SoundPath)) {
    return $false
  }

  if (Get-Command Invoke-RaymanAttentionSoundFile -ErrorAction SilentlyContinue) {
    try {
      return (Invoke-RaymanAttentionSoundFile -Path $SoundPath)
    } catch {}
  }

  return $false
}

function Invoke-RequestAttentionMain {
  param(
    [ValidateSet('manual', 'done', 'error')][string]$Kind = 'manual',
    [string]$Message = 'Rayman 需要您关注当前任务。',
    [string]$Title = 'Rayman 提醒',
    [string]$WorkspaceRoot = '',
    [switch]$EnableSpeech,
    [switch]$DisableSpeech,
    [switch]$DisableSound
  )

  $workspaceRoot = Resolve-AttentionWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
  $fullMessage = if ([string]::IsNullOrWhiteSpace($Message)) { 'Rayman 需要您关注当前任务。' } else { $Message.Trim() }
  $notificationEnabled = Test-AttentionNotificationEnabled -Kind $Kind -WorkspaceRoot $workspaceRoot
  $speechOverride = @{}
  if ($PSBoundParameters.ContainsKey('EnableSpeech')) {
    $speechOverride['EnableSpeech'] = $EnableSpeech
  }
  if ($PSBoundParameters.ContainsKey('DisableSpeech')) {
    $speechOverride['DisableSpeech'] = $DisableSpeech
  }
  $soundOverride = @{}
  if ($PSBoundParameters.ContainsKey('DisableSound')) {
    $soundOverride['DisableSound'] = $DisableSound
  }
  $speechEnabled = Resolve-AttentionSpeechEnabled -Kind $Kind -WorkspaceRoot $workspaceRoot @speechOverride
  $soundEnabled = Resolve-AttentionSoundEnabled -Kind $Kind -WorkspaceRoot $workspaceRoot @soundOverride
  $soundPath = if ($soundEnabled) { [string](Resolve-AttentionSoundPath -WorkspaceRoot $workspaceRoot) } else { '' }
  $surface = Resolve-AttentionSurface -WorkspaceRoot $workspaceRoot

  try {
    if (Get-Command Write-RaymanDiag -ErrorAction SilentlyContinue) {
      $diagKind = if ($notificationEnabled) { 'request_attention' } else { 'request_attention_suppressed' }
      Write-RaymanDiag -Scope 'attention' -Message ("{0} ({1}, surface={2}): {3}" -f $diagKind, $Kind, $surface, $fullMessage) -WorkspaceRoot $workspaceRoot
    }
  } catch {}

  Write-AttentionStateRecord `
    -WorkspaceRoot $workspaceRoot `
    -Kind $Kind `
    -Title $Title `
    -Message $fullMessage `
    -Surface $surface `
    -AlertEnabled $notificationEnabled `
    -SpeechEnabled $(if ($surface -eq 'toast') { $speechEnabled } else { $false }) `
    -Suppressed (-not $notificationEnabled)

  if (-not $notificationEnabled) {
    return
  }

  switch ($surface) {
    'log' {
      if (Get-Command Write-RaymanAttentionConsoleMessage -ErrorAction SilentlyContinue) {
        Write-RaymanAttentionConsoleMessage -Kind $Kind -Title $Title -Message $fullMessage
      } else {
        Write-Host ("[{0}] {1}" -f $Title, $fullMessage) -ForegroundColor Yellow
      }
      break
    }
    'toast' {
      try {
        $toastDelivered = ($env:OS -eq 'Windows_NT' -and (Show-WindowsToast -ToastTitle $Title -ToastMessage $fullMessage))
        if ($toastDelivered) {
        } elseif (Get-Command notify-send -ErrorAction SilentlyContinue) {
          & (Get-Command notify-send -ErrorAction SilentlyContinue).Source $Title $fullMessage | Out-Null
        } elseif (Get-Command Write-RaymanAttentionConsoleMessage -ErrorAction SilentlyContinue) {
          Write-RaymanAttentionConsoleMessage -Kind $Kind -Title $Title -Message $fullMessage
        } else {
          Write-Host ("[{0}] {1}" -f $Title, $fullMessage) -ForegroundColor Yellow
        }
      } catch {
        if (Get-Command Write-RaymanAttentionConsoleMessage -ErrorAction SilentlyContinue) {
          Write-RaymanAttentionConsoleMessage -Kind $Kind -Title $Title -Message $fullMessage
        } else {
          Write-Host ("[{0}] {1}" -f $Title, $fullMessage) -ForegroundColor Yellow
        }
      }
      break
    }
  }

  if ($soundEnabled) {
    Invoke-AttentionSound -SoundPath $soundPath | Out-Null
  }
  if ($speechEnabled) {
    Invoke-AttentionSpeech -SpeechText $fullMessage
  }
}

Invoke-RequestAttentionMain -Kind $Kind -Message $Message -Title $Title -WorkspaceRoot $WorkspaceRoot -EnableSpeech:$EnableSpeech -DisableSpeech:$DisableSpeech -DisableSound:$DisableSound
