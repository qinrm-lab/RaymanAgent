param()
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $root

$runtime = Join-Path $root '.Rayman\runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$snapshot = Join-Path $runtime 'projects.snapshot.txt'

function Get-Projects {
  & bash "./.Rayman/scripts/requirements/detect_projects.sh" 2>$null | Sort-Object -Unique
}

$current = [System.IO.Path]::GetTempFileName()
(Get-Projects) | Set-Content -Encoding utf8 -NoNewline:$false -Path $current

$added = @()
if (Test-Path $snapshot) {
  $old = Get-Content $snapshot
  $now = Get-Content $current
  $added = $now | Where-Object { $old -notcontains $_ }
} else {
  $added = Get-Content $current
}

if ($added.Count -gt 0) {
  Write-Host "[fast-init] new projects detected:"
  $added | ForEach-Object { Write-Host "[fast-init]   + $_" }
} else {
  Write-Host "[fast-init] no new projects"
}

& bash "./.Rayman/scripts/requirements/ensure_requirements.sh" | Out-Null
Copy-Item -Force $current $snapshot
Remove-Item -Force $current
Write-Host "[fast-init] done"
