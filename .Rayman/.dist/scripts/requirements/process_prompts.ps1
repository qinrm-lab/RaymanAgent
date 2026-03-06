Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "common.ps1 not found: $commonPath"
}
. $commonPath

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$raymanDir = Join-Path $workspaceRoot '.Rayman'
$inbox = Join-Path $raymanDir 'context\prompt.inbox.md'
$codex = Join-Path $raymanDir 'codex_fix_prompt.txt'
$state = Join-Path $raymanDir 'runtime\prompt.state'
$updateScript = Join-Path $PSScriptRoot 'update_from_prompt.ps1'
$ensureAlertWatchScript = Join-Path $PSScriptRoot '..\alerts\ensure_attention_watch.ps1'

if (Test-Path -LiteralPath $ensureAlertWatchScript -PathType Leaf) {
  try { & $ensureAlertWatchScript -WorkspaceRoot $workspaceRoot -Quiet | Out-Null } catch {}
}

function Sha1File([string]$p){
  $sha1=[System.Security.Cryptography.SHA1]::Create()
  $bytes=[System.IO.File]::ReadAllBytes($p)
  ($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}

function ProcessFile([string]$f){
  if(-not(Test-Path $f)){ return }
  if((Get-Item $f).Length -le 0){ return }
  $h=Sha1File $f
  $key=($f -replace "[\\/]", "_")
  $old=""
  if(Test-Path $state){
    $line=(Get-Content $state | Where-Object { $_ -like "$key=*" } | Select-Object -First 1)
    if($line){ $old=$line.Substring($key.Length+1) }
  }
  if($h -eq $old){ return }

  Write-Host "[prompt] detect change: $f"
  $cmdArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $updateScript,
    '-PromptFile', $f,
    '-WorkspaceRoot', $workspaceRoot
  )
  $psHost = Resolve-RaymanPowerShellHost
  if ([string]::IsNullOrWhiteSpace($psHost)) {
    Write-Warn ("[prompt] cannot find PowerShell host (pwsh/powershell); skip sync for {0}" -f $f)
    return
  }
  try {
    & $psHost @cmdArgs | Out-Host
  } catch {
    Write-Warn ("[prompt] invoke update script failed; prompt={0}; script={1}; host={2}; cwd={3}; error={4}" -f $f, $updateScript, $psHost, (Get-Location).Path, $_.Exception.Message)
    return
  }

  $exitCode = $LASTEXITCODE
  if($exitCode -ne 0){
    Write-Warn ("[prompt] requirements sync failed (exit={0}); prompt={1}; script={2}; cwd={3}; prompt state NOT updated; fix the prompt and retry" -f $exitCode, $f, $updateScript, (Get-Location).Path)
    return
  }

  $sd=Split-Path $state -Parent
  if(-not(Test-Path $sd)){ New-Item -ItemType Directory -Force -Path $sd | Out-Null }
  $lines=@()
  if(Test-Path $state){ $lines=Get-Content $state | Where-Object { $_ -notlike "$key=*" } }
  $lines += "$key=$h"
  Set-Content -Path $state -Value $lines -Encoding UTF8
}

$locationPushed = $false
try {
  Push-Location -LiteralPath $workspaceRoot
  $locationPushed = $true

  ProcessFile $inbox

  if(Test-Path $codex){
    $txt=Get-Content -Raw $codex
    if($txt -match "RAYMAN:USER_PROMPT:BEGIN"){
      $m=[Regex]::Match($txt,"(?s)RAYMAN:USER_PROMPT:BEGIN\\s*-->\\s*(.*?)\\s*<!--\\s*RAYMAN:USER_PROMPT:END")
      if($m.Success){
        $tmp=Join-Path $env:TEMP ("rayman_prompt_"+[Guid]::NewGuid().ToString("n")+".md")
        Set-Content -Path $tmp -Value $m.Groups[1].Value -Encoding UTF8
        ProcessFile $tmp
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      }
    }
  }
} finally {
  if($locationPushed){
    Pop-Location
  }
}
