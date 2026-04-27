param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path),
  [ValidateSet('list', 'diff', 'restore')][string]$Action = 'list',
  [string]$Name = '',
  [string]$Slug = '',
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'session_common.ps1')
$sharedSessionHelperPath = Join-Path $PSScriptRoot 'shared_session_common.ps1'
if (Test-Path -LiteralPath $sharedSessionHelperPath -PathType Leaf) {
  . $sharedSessionHelperPath
}
$eventHooksPath = Join-Path $PSScriptRoot '..\utils\event_hooks.ps1'
if (Test-Path -LiteralPath $eventHooksPath -PathType Leaf) {
  . $eventHooksPath -NoMain
}

function Resolve-RaymanRollbackRecord {
  param(
    [object[]]$Records,
    [string]$Name,
    [string]$Slug
  )

  $records = @($Records)
  if (-not [string]::IsNullOrWhiteSpace($Slug)) {
    return ($records | Where-Object { [string]$_.slug -eq $Slug } | Select-Object -First 1)
  }
  if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $targetSlug = ConvertTo-RaymanSessionSlug -Name $Name
    return ($records | Where-Object { [string]$_.slug -eq $targetSlug -or [string]$_.name -eq $Name } | Select-Object -First 1)
  }
  return $null
}

function Get-RaymanRollbackPatchSummary {
  param(
    [string]$WorkspaceRoot,
    [string]$PatchPath
  )

  $result = [ordered]@{
    mode = 'patch'
    source_path = $PatchPath
    file_count = 0
    files = @()
    summary_lines = @()
  }

  if ([string]::IsNullOrWhiteSpace($PatchPath) -or -not (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
    return [pscustomobject]$result
  }

  $gitPath = Get-RaymanGitCommandPath
  if (-not [string]::IsNullOrWhiteSpace($gitPath)) {
    $saved = Get-Location
    try {
      Set-Location -LiteralPath $WorkspaceRoot
      $stat = @(& $gitPath apply --stat --summary --numstat $PatchPath 2>$null)
      if ($LASTEXITCODE -eq 0 -and $stat.Count -gt 0) {
        $result.summary_lines = @($stat | ForEach-Object { [string]$_ })
      }
    } finally {
      Set-Location -LiteralPath $saved.Path
    }
  }

  $files = New-Object System.Collections.Generic.List[string]
  foreach ($line in @(Get-Content -LiteralPath $PatchPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if ($line -match '^diff --git a/(?<path>.+?) b/(?<path2>.+)$') {
      $pathValue = [string]$matches['path2']
      if (-not [string]::IsNullOrWhiteSpace($pathValue) -and $files -notcontains $pathValue) {
        $files.Add($pathValue) | Out-Null
      }
    }
  }
  $result.file_count = $files.Count
  $result.files = @($files.ToArray())
  return [pscustomobject]$result
}

function Get-RaymanRollbackWorktreeSummary {
  param([string]$WorktreePath)

  $result = [ordered]@{
    mode = 'worktree'
    source_path = $WorktreePath
    file_count = 0
    files = @()
    summary_lines = @()
  }
  if ([string]::IsNullOrWhiteSpace($WorktreePath) -or -not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
    return [pscustomobject]$result
  }

  $gitPath = Get-RaymanGitCommandPath
  if ([string]::IsNullOrWhiteSpace($gitPath)) {
    return [pscustomobject]$result
  }

  $status = @(& $gitPath -C $WorktreePath status --short 2>$null)
  $result.summary_lines = @($status | ForEach-Object { [string]$_ })
  $files = @($status | ForEach-Object {
      $text = [string]$_
      if ($text.Length -ge 4) { $text.Substring(3).Trim() }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $result.files = @($files)
  $result.file_count = $files.Count
  return [pscustomobject]$result
}

function Get-RaymanRollbackStashSummary {
  param(
    [string]$WorkspaceRoot,
    [string]$StashOid
  )

  $result = [ordered]@{
    mode = 'stash'
    source_path = $StashOid
    file_count = 0
    files = @()
    summary_lines = @()
  }
  if ([string]::IsNullOrWhiteSpace($StashOid)) {
    return [pscustomobject]$result
  }

  $gitPath = Get-RaymanGitCommandPath
  if ([string]::IsNullOrWhiteSpace($gitPath)) {
    return [pscustomobject]$result
  }

  $stashTarget = Get-RaymanGitStashRefByOid -WorkspaceRoot $WorkspaceRoot -StashOid $StashOid
  if ([string]::IsNullOrWhiteSpace($stashTarget)) {
    $stashTarget = $StashOid
  }

  $lines = @(& $gitPath -C $WorkspaceRoot stash show --stat $stashTarget 2>$null)
  $result.summary_lines = @($lines | ForEach-Object { [string]$_ })
  $fileLines = @($lines | Where-Object { [string]$_ -match '\|' })
  $files = @($fileLines | ForEach-Object {
      $text = [string]$_
      $text.Split('|')[0].Trim()
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $result.files = @($files)
  $result.file_count = $files.Count
  return [pscustomobject]$result
}

$resolvedWorkspaceRootInput = if ($PSBoundParameters.ContainsKey('WorkspaceRoot')) { [string]$PSBoundParameters['WorkspaceRoot'] } else { $WorkspaceRoot }
$ResolvedWorkspaceRoot = Get-RaymanStateWorkspaceRoot -WorkspaceRoot $resolvedWorkspaceRootInput
$records = @(Get-RaymanSessionRecords -WorkspaceRoot $ResolvedWorkspaceRoot -All | Where-Object { [string]$_.session_kind -in @('manual', 'auto_temp') })

switch ($Action) {
  'list' {
    $payload = [ordered]@{
      schema = 'rayman.rollback.list.v1'
      workspace_root = $ResolvedWorkspaceRoot
      count = $records.Count
      sessions = @($records | ForEach-Object {
          [ordered]@{
            name = [string]$_.name
            slug = [string]$_.slug
            session_kind = [string]$_.session_kind
            status = [string]$_.status
            backend = [string]$_.backend
            account_alias = [string]$_.account_alias
            owner_display = [string]$_.owner_display
            updated_at = [string]$_.updated_at
            task_description = [string]$_.task_description
            has_handover = (Test-Path -LiteralPath ([string]$_.handover_path) -PathType Leaf)
            has_patch = (Test-Path -LiteralPath ([string]$_.auto_save_patch_path) -PathType Leaf)
            has_meta = (Test-Path -LiteralPath ([string]$_.auto_save_meta_path) -PathType Leaf)
            has_stash = [bool]$_.has_stash
            has_worktree = [bool]$_.has_worktree
          }
        })
    }
    if ($Json) {
      $payload | ConvertTo-Json -Depth 10
      exit 0
    }

    if ($records.Count -eq 0) {
      Write-Host '没有找到可回滚的 session-backed checkpoints。'
      exit 0
    }
    Write-Host '可回滚 checkpoints：'
    foreach ($record in $records) {
      Write-Host ("- {0} | kind={1} | status={2} | backend={3} | owner={4} | patch={5} | stash={6} | worktree={7} | updated={8}" -f [string]$record.name, [string]$record.session_kind, [string]$record.status, [string]$record.backend, [string]$record.owner_display, [string](Test-Path -LiteralPath ([string]$record.auto_save_patch_path) -PathType Leaf).ToString().ToLowerInvariant(), [string]([bool]$record.has_stash).ToString().ToLowerInvariant(), [string]([bool]$record.has_worktree).ToString().ToLowerInvariant(), [string]$record.updated_at)
    }
    break
  }
  'diff' {
    $record = Resolve-RaymanRollbackRecord -Records $records -Name $Name -Slug $Slug
    if ($null -eq $record) {
      throw 'rollback diff requires an existing session name or slug.'
    }

    $patchSummary = Get-RaymanRollbackPatchSummary -WorkspaceRoot $ResolvedWorkspaceRoot -PatchPath ([string]$record.auto_save_patch_path)
    $worktreeSummary = Get-RaymanRollbackWorktreeSummary -WorktreePath ([string]$record.worktree_path)
    $stashSummary = Get-RaymanRollbackStashSummary -WorkspaceRoot $ResolvedWorkspaceRoot -StashOid ([string]$record.stash_oid)
    $payload = [ordered]@{
      schema = 'rayman.rollback.diff.v1'
      workspace_root = $ResolvedWorkspaceRoot
      session = [ordered]@{
        name = [string]$record.name
        slug = [string]$record.slug
        session_kind = [string]$record.session_kind
        status = [string]$record.status
        backend = [string]$record.backend
        account_alias = [string]$record.account_alias
      }
      patch = $patchSummary
      worktree = $worktreeSummary
      stash = $stashSummary
    }
    if ($Json) {
      $payload | ConvertTo-Json -Depth 12
      exit 0
    }

    Write-Host ("Rollback diff: {0}" -f [string]$record.name)
    foreach ($section in @(
        @{ label = 'patch'; data = $patchSummary }
        @{ label = 'worktree'; data = $worktreeSummary }
        @{ label = 'stash'; data = $stashSummary }
      )) {
      Write-Host ("[{0}] files={1}" -f [string]$section.label, [int]$section.data.file_count) -ForegroundColor DarkCyan
      foreach ($line in @($section.data.summary_lines | Select-Object -First 12)) {
        Write-Host ("  {0}" -f [string]$line)
      }
    }
    break
  }
  'restore' {
    $record = Resolve-RaymanRollbackRecord -Records $records -Name $Name -Slug $Slug
    if ($null -eq $record) {
      throw 'rollback restore requires an existing session name or slug.'
    }

    $resumeScript = Join-Path $PSScriptRoot 'resume_state.ps1'
    if (-not (Test-Path -LiteralPath $resumeScript -PathType Leaf)) {
      throw "resume_state.ps1 not found: $resumeScript"
    }

    $resumeKey = if (-not [string]::IsNullOrWhiteSpace([string]$record.slug)) { [string]$record.slug } else { [string]$record.name }
    $resumeOutput = @(& $resumeScript -WorkspaceRoot $ResolvedWorkspaceRoot -Name $resumeKey -AllowAlreadyResumed -Json)
    $resumeJson = (($resumeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($resumeJson)) {
      throw 'resume_state returned no JSON payload.'
    }
    $resumeResult = $resumeJson | ConvertFrom-Json -ErrorAction Stop
    $sharedRestore = $null
    $sharedRestoreError = ''
    if ((Get-Command Restore-RaymanSharedSessionCheckpoint -ErrorAction SilentlyContinue) -and (Get-Command Test-RaymanSharedSessionEnabled -ErrorAction SilentlyContinue) -and (Test-RaymanSharedSessionEnabled -WorkspaceRoot $ResolvedWorkspaceRoot)) {
      try {
        $sharedSessionId = Get-RaymanSharedSessionId -WorkspaceRoot $ResolvedWorkspaceRoot -TaskSlug ([string]$record.slug)
        $sharedRestore = Restore-RaymanSharedSessionCheckpoint -WorkspaceRoot $ResolvedWorkspaceRoot -SessionId $sharedSessionId -RestoredBy ('rollback:' + [string]$record.slug)
        if ($null -ne $sharedRestore -and [bool]$sharedRestore.restored -and (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue)) {
          Write-RaymanEvent -WorkspaceRoot $ResolvedWorkspaceRoot -EventType 'shared_session.restored' -Category 'state' -Payload ([ordered]@{
              session_id = [string]$sharedSessionId
              checkpoint_id = [string]$sharedRestore.checkpoint_id
              session_slug = [string]$record.slug
            }) | Out-Null
        }
      } catch {
        $sharedRestoreError = $_.Exception.Message
        if (-not $Json) {
          Write-Warning ("shared-session checkpoint restore failed during rollback: {0}" -f $sharedRestoreError)
        }
        if (Get-Command Write-RaymanDiag -ErrorAction SilentlyContinue) {
          Write-RaymanDiag -Scope 'shared-session' -WorkspaceRoot $ResolvedWorkspaceRoot -Message ("rollback shared-session restore failed; session_slug={0}; error={1}" -f [string]$record.slug, $_.Exception.ToString())
        }
        if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
          Write-RaymanEvent -WorkspaceRoot $ResolvedWorkspaceRoot -EventType 'shared_session.restore_failed' -Category 'state' -Payload ([ordered]@{
              session_slug = [string]$record.slug
              error = $sharedRestoreError
            }) | Out-Null
        }
      }
    }

    $payload = [ordered]@{
      schema = 'rayman.rollback.restore.v1'
      workspace_root = $ResolvedWorkspaceRoot
      restored = $true
      session_name = [string]$record.name
      session_slug = [string]$record.slug
      session_kind = [string]$record.session_kind
      resume_result = $resumeResult
      shared_session_restore = $sharedRestore
      shared_session_restore_error = $sharedRestoreError
    }
    if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
      Write-RaymanEvent -WorkspaceRoot $ResolvedWorkspaceRoot -EventType 'rollback.restore' -Category 'state' -Payload $payload | Out-Null
    }

    if ($Json) {
      $payload | ConvertTo-Json -Depth 12
      exit 0
    }

    Write-Host ("✅ 已恢复 checkpoint: {0}" -f [string]$record.name) -ForegroundColor Green
    break
  }
}
