param(
  [Parameter(Mandatory=$true)][string]$PromptFile,
  [string]$WorkspaceRoot = ''
)

$commonPath = Join-Path $PSScriptRoot "..\..\common.ps1"
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { throw "[req-from-prompt] missing prompt file: $PromptFile" }
$PromptFile = (Resolve-Path -LiteralPath $PromptFile).Path
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
  $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
} else {
  $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}

$detectSolutionScript = Join-Path $WorkspaceRoot '.Rayman\scripts\requirements\detect_solution.sh'
$detectProjectsScript = Join-Path $WorkspaceRoot '.Rayman\scripts\requirements\detect_projects.sh'

function Get-RaymanFirstNonEmptyLine([string[]]$Lines){
  foreach($l in $Lines){
    if($null -eq $l){ continue }
    $t = $l.Trim()
    if($t){ return $t }
  }
  return $null
}

function Invoke-RaymanBashScript([string]$Workspace, [string]$ScriptPath){
  if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    throw "bash not found in PATH"
  }
  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "script not found: $ScriptPath"
  }

  $scriptResolved = (Resolve-Path -LiteralPath $ScriptPath).Path
  $relative = $scriptResolved
  if ($scriptResolved.StartsWith($Workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
    $suffix = $scriptResolved.Substring($Workspace.Length).TrimStart('\','/')
    $relative = "./" + ($suffix -replace '\\','/')
  }

  $tmpBase = Join-Path $env:TEMP ("rayman_req_" + [Guid]::NewGuid().ToString("n"))
  $outFile = "$tmpBase.out.txt"
  $errFile = "$tmpBase.err.txt"
  try {
    $proc = Start-Process -FilePath 'bash' -ArgumentList @($relative) -WorkingDirectory $Workspace -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = @()
    $stderr = @()
    if (Test-Path -LiteralPath $outFile -PathType Leaf) { $stdout = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue) }
    if (Test-Path -LiteralPath $errFile -PathType Leaf) { $stderr = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) }
    return [pscustomobject]@{
      ExitCode         = $proc.ExitCode
      StdOut           = $stdout
      StdErr           = $stderr
      ScriptPath       = $scriptResolved
      Workspace        = $Workspace
      RelativeArgument = $relative
    }
  } finally {
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-RaymanBashFailureDetail([string]$Name, [pscustomobject]$Result){
  $stderrFirst = if($Result.StdErr -and $Result.StdErr.Count -gt 0){ $Result.StdErr[0] } else { '' }
  if($Result.ExitCode -eq 126){
    return ("{0} cannot execute (exit=126); script={1}; arg={2}; cwd={3}; stderr={4}" -f $Name, $Result.ScriptPath, $Result.RelativeArgument, $Result.Workspace, $stderrFirst)
  }
  if($Result.ExitCode -eq 127){
    return ("{0} not found in bash (exit=127); script={1}; arg={2}; cwd={3}; stderr={4}" -f $Name, $Result.ScriptPath, $Result.RelativeArgument, $Result.Workspace, $stderrFirst)
  }
  return ("{0} failed (exit={1}); script={2}; arg={3}; cwd={4}; stderr={5}" -f $Name, $Result.ExitCode, $Result.ScriptPath, $Result.RelativeArgument, $Result.Workspace, $stderrFirst)
}

function Normalize-RaymanWorkspaceName([string]$Name){
  if($null -eq $Name){ return '' }
  return $Name.Trim().ToLowerInvariant()
}

function Test-RaymanReservedWorkspacePrefix([string]$Name){
  $key = Normalize-RaymanWorkspaceName $Name
  switch($key){
    'target' { return $true }
    'workspace' { return $true }
    '工作区' { return $true }
    '功能' { return $true }
    '需求' { return $true }
    '验收标准' { return $true }
    '验收' { return $true }
    'feature' { return $true }
    'features' { return $true }
    'requirement' { return $true }
    'requirements' { return $true }
    'acceptance criteria' { return $true }
    'ac' { return $true }
    '附件' { return $true }
    'attachment' { return $true }
    'attachments' { return $true }
    '问题' { return $true }
    'issue' { return $true }
    'issues' { return $true }
    'closed' { return $true }
    'resolved' { return $true }
    '已解决' { return $true }
    '已修复' { return $true }
    default { return $false }
  }
}

function Get-RaymanPromptWorkspaceDirective([string]$PromptText){
  if([string]::IsNullOrWhiteSpace($PromptText)){ return $null }
  $lines = ($PromptText -replace "`r","").Split("`n")

  # Priority 1: explicit field anywhere in prompt.
  foreach($line in $lines){
    if($null -eq $line){ continue }
    $l = $line.Trim()
    if(-not $l){ continue }
    $m = [Regex]::Match($l, '^(?i:workspace|工作区)\s*[:：]\s*(.+?)\s*$')
    if($m.Success){
      $name = $m.Groups[1].Value.Trim()
      if($name){
        return [pscustomobject]@{
          Name = $name
          Source = 'field'
        }
      }
    }
  }

  # Priority 2: first non-empty non-comment line "<WorkspaceName>: ...".
  foreach($line in $lines){
    if($null -eq $line){ continue }
    $l = $line.Trim()
    if(-not $l){ continue }
    if($l.StartsWith('#') -or $l.StartsWith('<!--')){ continue }

    $m = [Regex]::Match($l, '^([^:：]+)\s*[:：].*$')
    if($m.Success){
      $candidate = $m.Groups[1].Value.Trim()
      if($candidate -and -not (Test-RaymanReservedWorkspacePrefix $candidate)){
        return [pscustomobject]@{
          Name = $candidate
          Source = 'prefix'
        }
      }
    }
    break
  }

  return $null
}

function Add-RaymanWorkspaceAlias([System.Collections.Generic.List[string]]$Aliases, [string]$Alias){
  if($null -eq $Aliases){ return }
  if([string]::IsNullOrWhiteSpace($Alias)){ return }
  $norm = Normalize-RaymanWorkspaceName $Alias
  if(-not $norm){ return }
  foreach($existing in $Aliases){
    if((Normalize-RaymanWorkspaceName $existing) -eq $norm){ return }
  }
  $Aliases.Add($Alias.Trim()) | Out-Null
}

$locationPushed = $false
try {
  Push-Location -LiteralPath $WorkspaceRoot
  $locationPushed = $true

  $solResult = Invoke-RaymanBashScript -Workspace $WorkspaceRoot -ScriptPath $detectSolutionScript
  if($solResult.ExitCode -ne 0){
    $detail = Get-RaymanBashFailureDetail -Name 'detect_solution.sh' -Result $solResult
    if ($solResult.ExitCode -eq 2 -or (($solResult.StdErr -join "`n") -match '无法推断 SolutionName')) {
      throw "[req-from-prompt] cannot detect solution: $detail"
    }
    throw "[req-from-prompt] cannot detect solution (bash invocation failed): $detail"
  }

  $sol = Get-RaymanFirstNonEmptyLine -Lines $solResult.StdOut
  if (-not $sol) {
    $detail = Get-RaymanBashFailureDetail -Name 'detect_solution.sh' -Result $solResult
    throw "[req-from-prompt] cannot detect solution: $detail"
  }
  $solDir = ".$sol"
  $solReq = (Join-Path $solDir ".$sol.requirements.md")

  $projs = @()
  try {
    $projResult = Invoke-RaymanBashScript -Workspace $WorkspaceRoot -ScriptPath $detectProjectsScript
    if ($projResult.ExitCode -eq 0) {
      $projs = @($projResult.StdOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    } else {
      $detail = Get-RaymanBashFailureDetail -Name 'detect_projects.sh' -Result $projResult
      Write-Warn ("[req-from-prompt] detect projects failed: {0}" -f $detail)
      $projs = @()
    }
  } catch {
    Write-Warn ("[req-from-prompt] detect projects exception: {0}" -f $_.Exception.Message)
    $projs = @()
  }

  $promptTxt = Get-Content -Raw -LiteralPath $PromptFile

  $workspaceAliases = New-Object System.Collections.Generic.List[string]
  Add-RaymanWorkspaceAlias -Aliases $workspaceAliases -Alias $sol
  Add-RaymanWorkspaceAlias -Aliases $workspaceAliases -Alias (Split-Path -Leaf $WorkspaceRoot)

  $declaredWorkspaceDirective = Get-RaymanPromptWorkspaceDirective -PromptText $promptTxt
  if($declaredWorkspaceDirective -and -not [string]::IsNullOrWhiteSpace($declaredWorkspaceDirective.Name)){
    $declaredNorm = Normalize-RaymanWorkspaceName $declaredWorkspaceDirective.Name
    $matchedWorkspace = $false
    foreach($alias in $workspaceAliases){
      if((Normalize-RaymanWorkspaceName $alias) -eq $declaredNorm){
        $matchedWorkspace = $true
        break
      }
    }

    if(-not $matchedWorkspace){
      $aliasText = if($workspaceAliases.Count -gt 0){ (($workspaceAliases | Select-Object -Unique) -join ', ') } else { $sol }
      try {
        if (Get-Command Invoke-RaymanAttentionAlert -ErrorAction SilentlyContinue) {
          Invoke-RaymanAttentionAlert -Kind 'manual' -Reason '检测到跨工作区 prompt，已暂停同步。' -MaxSeconds (Get-RaymanEnvInt -Name 'RAYMAN_ALERT_TARGET_SELECT_MAX_SECONDS' -Default 60 -Min 5 -Max 3600) | Out-Null
        }
      } catch {}

      [Console]::Error.WriteLine("[req-from-prompt] 检测到跨工作区 prompt，已暂停；prompt 仅能对本工作区负责。")
      [Console]::Error.WriteLine(("[req-from-prompt] declared workspace: {0}; current workspace aliases: {1}" -f $declaredWorkspaceDirective.Name, $aliasText))
      exit 65
    }
  }

function TrimStr([string]$s){ if($null -eq $s){ return "" }; return $s.Trim() }

function GetNowTs(){
  # ISO8601 w/ timezone, seconds precision
  return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
}

function TsToEpoch([string]$ts){
  try { return [DateTimeOffset]::Parse($ts).ToUnixTimeSeconds() } catch { return $null }
}

function EpochToTs([long]$e){
  try { return [DateTimeOffset]::FromUnixTimeSeconds($e).ToString('yyyy-MM-ddTHH:mm:ssK') } catch { return GetNowTs }
}

function StripVisibleTsPrefix([string]$s){
  if($null -eq $s){ return "" }
  return (($s -replace '^\[[^\]]+\]\s*','').Trim())
}

function EnsureSyncMeta(){
  $nowTs = GetNowTs
  $nowEpoch = [DateTimeOffset]::Now.ToUnixTimeSeconds()
  $begin = '<!-- RAYMAN:SYNC_META:BEGIN -->'
  $end = '<!-- RAYMAN:SYNC_META:END -->'
  $block = @(
    $begin,
    "- LastSyncedAt: $nowTs",
    "- LastSyncedUnix: $nowEpoch",
    "- UpdatedBy: .Rayman/scripts/requirements/update_from_prompt.ps1",
    $end
  ) -join "`n"

  $content = Get-Content -Raw -Path $target
  if($content -match [Regex]::Escape($begin)){
    $rx = [Regex]::new("(?s)" + [Regex]::Escape($begin) + ".*?" + [Regex]::Escape($end))
    $content = $rx.Replace($content, $block)
    Set-Content -Path $target -Value $content -Encoding UTF8
    return
  }

  Add-Content -Path $target -Value ""
  Add-Content -Path $target -Value "## 同步元数据（自动维护）"
  Add-Content -Path $target -Value ""
  Add-Content -Path $target -Value $block
}

function BackfillBlockTs(){
  $content = Get-Content -Raw -Path $target
  $rx = [Regex]::new('<!--\s*RAYMAN:(FEATURE|ACCEPT|ATTACH|ISSUE):BEGIN\s+id=([0-9a-f]{40})(?![^>]*\sts=)([^>]*)-->')
  if(-not $rx.IsMatch($content)){ return }

  $nowTs = GetNowTs
  $newContent = $rx.Replace($content, {
    param($m)
    $kind = $m.Groups[1].Value
    $id = $m.Groups[2].Value
    return "<!-- RAYMAN:${kind}:BEGIN id=$id ts=$nowTs -->"
  })

  Set-Content -Path $target -Value $newContent -Encoding UTF8
  Write-Host "[req-from-prompt] backfilled missing block ts"
}

function Norm([string]$s){ return ($s.ToLowerInvariant() -replace "\s+"," ").Trim() }
function Sha1([string]$s){
  $sha1=[System.Security.Cryptography.SHA1]::Create()
  $b=[System.Text.Encoding]::UTF8.GetBytes($s)
  ($sha1.ComputeHash($b) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function Get-RaymanLocalEnvBool([string]$Name, [bool]$Default = $false){
  if(Get-Command Get-RaymanEnvBool -ErrorAction SilentlyContinue){
    try { return (Get-RaymanEnvBool -Name $Name -Default $Default) } catch {}
  }
  $raw = [System.Environment]::GetEnvironmentVariable($Name)
  if([string]::IsNullOrWhiteSpace($raw)){ return $Default }
  switch($raw.Trim().ToLowerInvariant()){
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $Default }
  }
}

$features=New-Object System.Collections.Generic.List[string]
$accepts=New-Object System.Collections.Generic.List[string]
$attachments=New-Object System.Collections.Generic.List[string]
$section=""

$lines = ($promptTxt -replace "`r","").Split("`n")
foreach($line in $lines){
  $l=$line.Trim()
  if(-not $l){ continue }
  if($l -match "^(#+\s*)?(功能|需求|Feature|Requirement)s?[:：]?$"){ $section="feature"; continue }
  if($l -match "^(#+\s*)?(验收标准|验收|Acceptance Criteria|AC)[:：]?$"){ $section="accept"; continue }
  if($l -match "^(#+\s*)?(附件|Attachments?)[:：]?$"){ $section="attach"; continue }

  if($section -eq "feature" -and $l -match "^(-|\*|\d+\.)\s+"){
    $it=($l -replace "^(-|\*|\d+\.)\s+","").Trim(); if($it){ $features.Add($it) }
  }
  if($section -eq "accept" -and $l -match "^(-|\*|\d+\.)\s+"){
    $it=($l -replace "^(-|\*|\d+\.)\s+","").Trim(); if($it){ $accepts.Add($it) }
  }
  if($section -eq "attach" -and $l -match "^(-|\*|\d+\.)\s+"){
    $it=($l -replace "^(-|\*|\d+\.)\s+","").Trim(); if($it){ $attachments.Add($it) }
  }
}
if($features.Count -eq 0){
  foreach($line in $lines){ if($line -match "^(功能|需求)[:：]"){ $it=($line -replace "^(功能|需求)[:：]\s*","").Trim(); if($it){$features.Add($it)} } }
}
if($accepts.Count -eq 0){
  foreach($line in $lines){ if($line -match "^(验收标准|验收|AC)[:：]"){ $it=($line -replace "^(验收标准|验收|AC)[:：]\s*","").Trim(); if($it){$accepts.Add($it)} } }
}

if($attachments.Count -eq 0){
  foreach($line in $lines){ if($line -match "^(附件|Attachment)s?[:：]"){ $it=($line -replace "^(附件|Attachment)s?[:：]\s*","").Trim(); if($it){$attachments.Add($it)} } }
}
if($features.Count -eq 0 -and $accepts.Count -eq 0 -and $attachments.Count -eq 0){
  Write-Host "[req-from-prompt] no feature/acceptance/attachment detected (skip)"; exit 0
}

# Choose target (only when there is actionable content)
$targetSpec = $null
$m = [regex]::Match($promptTxt, '(?im)^\s*Target\s*[:：]\s*(.+?)\s*$')
if($m.Success){ $targetSpec = TrimStr $m.Groups[1].Value }
$strictTarget = Get-RaymanLocalEnvBool -Name 'RAYMAN_PROMPT_TARGET_STRICT' -Default $false

if(-not $targetSpec){
  if($Host.UI.RawUI){
    try {
      Invoke-RaymanAttentionAlert -Kind 'manual' -Reason '需要选择 Target（Solution/Project）后才能继续。' -MaxSeconds (Get-RaymanEnvInt -Name 'RAYMAN_ALERT_TARGET_SELECT_MAX_SECONDS' -Default 300 -Min 5 -Max 3600) | Out-Null
    } catch {}
    Write-Host ""
    Write-Host "[req-from-prompt] Target is required to avoid mixing solution/project requirements."
    Write-Host "Please choose where to write this prompt:"
    Write-Host "  0) Abort"
    Write-Host "  1) Solution ($solReq)"
    $i = 2
    foreach($p in $projs){
      Write-Host ("  {0}) Project: {1} ({2})" -f $i, $p, (Join-Path $solDir ".$p\.$p.requirements.md"))
      $i++
    }
    $sel = TrimStr (Read-Host "Select [0-$($i-1)]")
    if($sel -eq '1'){ $targetSpec = 'Solution' }
    elseif($sel -match '^\d+$' -and [int]$sel -ge 2 -and [int]$sel -le ($i-1)){
      $p = $projs[[int]$sel - 2]
      $targetSpec = "Project:$p"
    } else {
      Write-Error "[req-from-prompt] abort (no target selected)"
      exit 64
      }
    } else {
      if($strictTarget){
        Write-Error "[req-from-prompt] Target is required to avoid mixing Solution vs Project requirements."
        Write-Error "[req-from-prompt] Add one of:"
        Write-Error ('  ' + 'Target: Solution')
        Write-Error ('  ' + 'Target: Project:<ProjectName>')
        if($projs.Count -gt 0){
          Write-Error "[req-from-prompt] Detected projects:"
          $i=1
          foreach($p in $projs){
            Write-Error ("  {0}) {1}    (use: Target: Project:{1})" -f $i,$p)
            $i++
          }
        }
        exit 64
      } else {
        Write-Warn ("[req-from-prompt] Target missing; fallback to Solution: {0} (set RAYMAN_PROMPT_TARGET_STRICT=1 to enforce strict mode)" -f $solReq)
        $targetSpec = 'Solution'
      }
    }
  }

$target = $null
if($targetSpec -match '^Solution$'){
  $target = $solReq
} elseif($targetSpec -match '^Project\s*[:：]'){
  $proj = TrimStr ($targetSpec -replace '^Project\s*[:：]\s*','')
  if(-not $proj){
    if($strictTarget){
      Write-Error "[req-from-prompt] invalid Target (missing project name): $targetSpec"
      exit 64
    }
    Write-Warn ("[req-from-prompt] invalid Target (missing project name): {0}; fallback to Solution: {1}" -f $targetSpec, $solReq)
    $target = $solReq
  }
  if($proj){
    if($projs -notcontains $proj){
      if($strictTarget){
        Write-Error "[req-from-prompt] unknown project in Target: $proj"
        if($projs.Count -gt 0){ Write-Error "[req-from-prompt] Detected projects: $($projs -join ', ')" }
        exit 64
      }
      $detected = if($projs.Count -gt 0){ $projs -join ', ' } else { '(none)' }
      Write-Warn ("[req-from-prompt] unknown project in Target: {0}; detected={1}; fallback to Solution: {2}" -f $proj, $detected, $solReq)
      $target = $solReq
    }
    if(-not $target){ $target = Join-Path $solDir ".$proj\.$proj.requirements.md" }
  }
} else {
  if($strictTarget){
    Write-Error ('[req-from-prompt] invalid Target: ' + $targetSpec + " (expected 'Solution' or 'Project:<ProjectName>')")
    if($projs.Count -gt 0){
      Write-Error "[req-from-prompt] examples:"
      Write-Error "  Target: Solution"
      foreach($p in $projs){ Write-Error "  Target: Project:$p" }
    }
    exit 64
  } else {
    Write-Warn ("[req-from-prompt] invalid Target: {0}; fallback to Solution: {1}" -f $targetSpec, $solReq)
    $target = $solReq
  }
}

$td=Split-Path $target -Parent
if(-not(Test-Path $td)){ New-Item -ItemType Directory -Force -Path $td | Out-Null }
if(-not(Test-Path $target)){ New-Item -ItemType File -Force -Path $target | Out-Null }

function EnsureSection([string]$title){
  $c=Get-Content -Raw -Path $target
  if($c -notmatch [Regex]::Escape($title)){
    Add-Content -Path $target -Value ""
    Add-Content -Path $target -Value $title
    Add-Content -Path $target -Value ""
    Add-Content -Path $target -Value "<!-- RAYMAN:AUTOGEN: marker blocks are managed automatically -->"
    Add-Content -Path $target -Value ""
  }
}
EnsureSection "## 功能需求（来自Prompt，自动维护）"
EnsureSection "## 验收标准（来自Prompt，自动维护）"
EnsureSection "## 附件（来自Prompt，自动维护，可手工追加）"
EnsureSyncMeta
BackfillBlockTs

function Upsert([string]$kind,[string]$text){
  if(-not (TrimStr $text)) { return }
  $norm=Norm $text
  $id=Sha1 $norm
  $nowTs = GetNowTs
  $nowEpoch = TsToEpoch $nowTs
  if($null -eq $nowEpoch){ $nowEpoch = [DateTimeOffset]::Now.ToUnixTimeSeconds() }

  $beginPrefix="<!-- RAYMAN:${kind}:BEGIN id=$id"
  $begin="<!-- RAYMAN:${kind}:BEGIN id=$id ts=$nowTs -->"
  $end="<!-- RAYMAN:${kind}:END id=$id -->"
  $cleanText = StripVisibleTsPrefix $text
  $visibleText = "[$nowTs] $cleanText"
  $block="$begin`n- $visibleText`n$end"
  $content=Get-Content -Raw -Path $target
  if($content -match [Regex]::Escape($beginPrefix)){
    # Extract existing begin line and ts
    $beginLine = ($content -split "`n" | Where-Object { $_ -like "*$beginPrefix*" } | Select-Object -First 1)
    $oldTs = $null
    if($beginLine -match 'ts=([^\s>]+)'){ $oldTs = $Matches[1] }
    $oldEpoch = if($oldTs){ TsToEpoch $oldTs } else { $null }
    if($null -eq $oldEpoch){
      $oldEpoch = $nowEpoch - 60
      $oldTs = EpochToTs $oldEpoch
      # backfill begin line ts
      if($beginLine){
        $beginLineNew = "<!-- RAYMAN:${kind}:BEGIN id=$id ts=$oldTs -->"
        $content = $content.Replace($beginLine, $beginLineNew)
      }
    }

    $escapedBeginPrefix = [Regex]::Escape($beginPrefix)
    $escapedEnd = [Regex]::Escape($end)
    $rxBlock = [Regex]::new("(?s)$escapedBeginPrefix[^>]*-->\s*(.*?)$escapedEnd")
    $m2 = $rxBlock.Match($content)
    $inside = ($m2.Groups[1].Value -replace "`r","").Trim()
    $existing = ($inside -split "`n" |
      ForEach-Object { ($_ -replace "^- ","").Trim() } |
      ForEach-Object { StripVisibleTsPrefix $_ } |
      Where-Object { $_ }) -join " / "
    $exNorm = Norm $existing

    if($exNorm -ne $norm){
      if($nowEpoch -le $oldEpoch){
        Write-Host "[req-from-prompt] keep $kind (new ts<=old ts): $id"
        # Persist any backfill edits
        Set-Content -Path $target -Value $content -Encoding UTF8
        return
      }
    }

    $rxReplace=[Regex]::new("(?s)$escapedBeginPrefix[^>]*-->.*?$escapedEnd")
    $content=$rxReplace.Replace($content,$block)
    Set-Content -Path $target -Value $content -Encoding UTF8
    Write-Host "[req-from-prompt] updated ${kind}: $id"
  } else {
    Add-Content -Path $target -Value ""
    Add-Content -Path $target -Value $block
    Write-Host "[req-from-prompt] added ${kind}: $id"
  }
}
foreach($f in $features){ Upsert "FEATURE" $f }
foreach($a in $accepts){ Upsert "ACCEPT" $a }
foreach($x in $attachments){ Upsert "ATTACH" $x }

# Prune legacy empty blocks (sha1 of empty string)
$emptyId = 'da39a3ee5e6b4b0d3255bfef95601890afd80709'
function PruneEmpty([string]$kind){
  $beginPrefix = "<!-- RAYMAN:${kind}:BEGIN id=$emptyId"
  $end = "<!-- RAYMAN:${kind}:END id=$emptyId -->"
  $content = Get-Content -Raw -Path $target
  if($content -notmatch [Regex]::Escape($beginPrefix)) { return }
  $escapedBeginPrefix = [Regex]::Escape($beginPrefix)
  $escapedEnd = [Regex]::Escape($end)
  $rx = [Regex]::new("(?s)\s*$escapedBeginPrefix[^>]*-->\s*(?:-\s*)?\s*$escapedEnd\s*")
  $content = $rx.Replace($content, "")
  Set-Content -Path $target -Value $content -Encoding UTF8
}
PruneEmpty 'FEATURE'
PruneEmpty 'ACCEPT'
PruneEmpty 'ATTACH'
PruneEmpty 'ISSUE'
Write-Host "[req-from-prompt] wrote: $target"
} finally {
  if($locationPushed){
    Pop-Location
  }
}
