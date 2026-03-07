param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [ValidateSet('list','show','apply')][string]$Action = 'list',
  [string]$Name = '',
  [string]$OutputPath = '',
  [string]$Task = '',
  [string]$AcceptanceCriteria = '',
  [string]$Notes = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$promptDir = Join-Path $WorkspaceRoot '.github\prompts'

if (-not (Test-Path -LiteralPath $promptDir -PathType Container)) {
  Write-Host ("[prompts] missing directory: {0}" -f $promptDir) -ForegroundColor Yellow
  exit 2
}

$templates = @(Get-ChildItem -LiteralPath $promptDir -Filter '*.prompt.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($templates.Count -eq 0) {
  Write-Host ("[prompts] no templates found in: {0}" -f $promptDir) -ForegroundColor Yellow
  exit 2
}

if ($Action -eq 'list') {
  Write-Host "Rayman Prompt Templates:"
  foreach ($t in $templates) {
    Write-Host ("- {0}" -f $t.Name)
  }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Name)) {
  Write-Host "[prompts] --name is required for show/apply" -ForegroundColor Red
  exit 2
}

$template = $null
foreach ($t in $templates) {
  if ($t.Name.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase) -or $t.BaseName.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
    $template = $t
    break
  }
}

if ($null -eq $template) {
  Write-Host ("[prompts] template not found: {0}" -f $Name) -ForegroundColor Red
  Write-Host ("[prompts] available: {0}" -f (($templates | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
  exit 2
}

$content = Get-Content -LiteralPath $template.FullName -Raw -Encoding UTF8

if ($Action -eq 'show') {
  Write-Output $content
  exit 0
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $WorkspaceRoot '.Rayman\context\prompt.generated.md'
} elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath = Join-Path $WorkspaceRoot $OutputPath
}

$result = $content
$result = $result.Replace('{{TASK}}', $Task)
$result = $result.Replace('{{ACCEPTANCE_CRITERIA}}', $AcceptanceCriteria)
$result = $result.Replace('{{NOTES}}', $Notes)
$result = $result.Replace('{{TIMESTAMP}}', (Get-Date).ToString('o'))
$result = $result.Replace('{{WORKSPACE_ROOT}}', $WorkspaceRoot)

$parent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $result -Encoding UTF8
Write-Host ("✅ [prompts] generated: {0}" -f $OutputPath) -ForegroundColor Green
