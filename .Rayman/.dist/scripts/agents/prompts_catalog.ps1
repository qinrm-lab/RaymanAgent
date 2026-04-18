param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [ValidateSet('list', 'show', 'apply', 'eval')][string]$Action = 'list',
  [string]$Name = '',
  [string]$OutputPath = '',
  [string]$Task = '',
  [string]$AcceptanceCriteria = '',
  [string]$Notes = '',
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot '..\..\common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
  . $commonPath
}
$eventHooksPath = Join-Path $PSScriptRoot '..\utils\event_hooks.ps1'
if (Test-Path -LiteralPath $eventHooksPath -PathType Leaf) {
  . $eventHooksPath -NoMain
}

function Get-RaymanPromptTemplateDirectory {
  param([string]$WorkspaceRoot)

  return (Join-Path $WorkspaceRoot '.github\prompts')
}

function Get-RaymanPromptTemplates {
  param([string]$WorkspaceRoot)

  $promptDir = Get-RaymanPromptTemplateDirectory -WorkspaceRoot $WorkspaceRoot
  if (-not (Test-Path -LiteralPath $promptDir -PathType Container)) {
    return @()
  }
  return @(Get-ChildItem -LiteralPath $promptDir -Filter '*.prompt.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Resolve-RaymanPromptTemplate {
  param(
    [string]$WorkspaceRoot,
    [string]$Name
  )

  foreach ($template in @(Get-RaymanPromptTemplates -WorkspaceRoot $WorkspaceRoot)) {
    if ($template.Name.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase) -or $template.BaseName.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $template
    }
  }
  return $null
}

function Render-RaymanPromptTemplate {
  param(
    [string]$TemplateContent,
    [string]$WorkspaceRoot,
    [string]$Task,
    [string]$AcceptanceCriteria,
    [string]$Notes
  )

  $result = [string]$TemplateContent
  $result = $result.Replace('{{TASK}}', $Task)
  $result = $result.Replace('{{ACCEPTANCE_CRITERIA}}', $AcceptanceCriteria)
  $result = $result.Replace('{{NOTES}}', $Notes)
  $result = $result.Replace('{{TIMESTAMP}}', (Get-Date).ToString('o'))
  $result = $result.Replace('{{WORKSPACE_ROOT}}', $WorkspaceRoot)
  return $result
}

function Get-RaymanPromptEvalSuites {
  param([string]$WorkspaceRoot)

  $path = Join-Path $WorkspaceRoot '.Rayman\config\prompt_eval_suites.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "prompt eval suite config missing: $path"
  }
  $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  if ([string]$config.schema -ne 'rayman.prompt_eval_suites.v1') {
    throw "unexpected prompt eval suite schema: $([string]$config.schema)"
  }
  return $config
}

function Test-RaymanPromptEvalCase {
  param(
    [string]$WorkspaceRoot,
    [object]$Suite,
    [object]$Case,
    [object]$Template
  )

  $templateContent = Get-Content -LiteralPath $Template.FullName -Raw -Encoding UTF8
  $rendered = Render-RaymanPromptTemplate -TemplateContent $templateContent -WorkspaceRoot $WorkspaceRoot -Task ([string]$Case.task) -AcceptanceCriteria ([string]$Case.acceptance_criteria) -Notes ([string]$Case.notes)
  $expectedContains = @($Case.expected_contains | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $forbiddenContains = @($Case.forbidden_contains | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $failures = New-Object System.Collections.Generic.List[string]

  foreach ($needle in $expectedContains) {
    if ($rendered -notmatch [regex]::Escape($needle)) {
      $failures.Add(("missing expected token: {0}" -f $needle)) | Out-Null
    }
  }
  foreach ($needle in $forbiddenContains) {
    if ($rendered -match [regex]::Escape($needle)) {
      $failures.Add(("forbidden token remained: {0}" -f $needle)) | Out-Null
    }
  }
  foreach ($placeholder in @('{{TASK}}', '{{ACCEPTANCE_CRITERIA}}', '{{NOTES}}')) {
    if ($rendered.Contains($placeholder)) {
      $failures.Add(("unresolved placeholder: {0}" -f $placeholder)) | Out-Null
    }
  }

  $renderHash = ''
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($rendered)
    $renderHash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }

  return [pscustomobject]@{
    suite_id = [string]$Suite.id
    case_id = [string]$Case.id
    prompt = [string]$Template.Name
    passed = ($failures.Count -eq 0)
    failure_count = $failures.Count
    failures = @($failures.ToArray())
    render_hash = $renderHash
    rendered_prompt = $rendered
  }
}

function Invoke-RaymanPromptEval {
  param(
    [string]$WorkspaceRoot,
    [string]$Name = ''
  )

  $config = Get-RaymanPromptEvalSuites -WorkspaceRoot $WorkspaceRoot
  $templates = @(Get-RaymanPromptTemplates -WorkspaceRoot $WorkspaceRoot)
  if ($templates.Count -eq 0) {
    throw "no templates found in $(Get-RaymanPromptTemplateDirectory -WorkspaceRoot $WorkspaceRoot)"
  }

  $selectedSuites = @($config.suites)
  if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $selectedSuites = @($selectedSuites | Where-Object { [string]$_.id -eq $Name })
    if ($selectedSuites.Count -eq 0) {
      throw "prompt eval suite not found: $Name"
    }
  }

  $runtimeDir = Join-Path $WorkspaceRoot '.Rayman\runtime\prompt_evals'
  if (-not (Test-Path -LiteralPath $runtimeDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  }

  $results = New-Object System.Collections.Generic.List[object]
  foreach ($suite in $selectedSuites) {
    foreach ($promptName in @($suite.prompts | ForEach-Object { [string]$_ })) {
      $template = Resolve-RaymanPromptTemplate -WorkspaceRoot $WorkspaceRoot -Name $promptName
      if ($null -eq $template) {
        $results.Add([pscustomobject]@{
            suite_id = [string]$suite.id
            case_id = ''
            prompt = $promptName
            passed = $false
            failure_count = 1
            failures = @("template not found: $promptName")
            render_hash = ''
            rendered_prompt = ''
          }) | Out-Null
        continue
      }
      foreach ($case in @($suite.cases)) {
        $results.Add((Test-RaymanPromptEvalCase -WorkspaceRoot $WorkspaceRoot -Suite $suite -Case $case -Template $template)) | Out-Null
      }
    }
  }

  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $jsonPath = Join-Path $runtimeDir ("prompt_eval.{0}.json" -f $timestamp)
  $mdPath = Join-Path $runtimeDir ("prompt_eval.{0}.md" -f $timestamp)
  $lastJsonPath = Join-Path $runtimeDir 'last.json'
  $lastMdPath = Join-Path $runtimeDir 'last.md'
  $passedCount = @($results | Where-Object { [bool]$_.passed }).Count
  $failedCount = @($results | Where-Object { -not [bool]$_.passed }).Count

  $payload = [ordered]@{
    schema = 'rayman.prompt_eval.v1'
    generated_at = (Get-Date).ToString('o')
    workspace_root = $WorkspaceRoot
    suite_count = $selectedSuites.Count
    result_count = $results.Count
    passed_count = $passedCount
    failed_count = $failedCount
    suites = @($selectedSuites | ForEach-Object { [string]$_.id })
    results = @($results.ToArray())
    artifacts = [ordered]@{
      json_path = $jsonPath
      markdown_path = $mdPath
      last_json_path = $lastJsonPath
      last_markdown_path = $lastMdPath
    }
  }

  ($payload | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $jsonPath -Encoding UTF8
  Copy-Item -LiteralPath $jsonPath -Destination $lastJsonPath -Force

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Rayman Prompt Eval') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(("- suite_count: {0}" -f [int]$payload.suite_count)) | Out-Null
  $lines.Add(("- result_count: {0}" -f [int]$payload.result_count)) | Out-Null
  $lines.Add(("- passed_count: {0}" -f [int]$payload.passed_count)) | Out-Null
  $lines.Add(("- failed_count: {0}" -f [int]$payload.failed_count)) | Out-Null
  $lines.Add('') | Out-Null
  foreach ($item in @($results.ToArray())) {
    $status = if ([bool]$item.passed) { 'PASS' } else { 'FAIL' }
    $lines.Add(("## [{0}] {1} :: {2} :: {3}" -f $status, [string]$item.suite_id, [string]$item.case_id, [string]$item.prompt)) | Out-Null
    $lines.Add('') | Out-Null
    if (@($item.failures).Count -eq 0) {
      $lines.Add('- no failures') | Out-Null
    } else {
      foreach ($failure in @($item.failures)) {
        $lines.Add(("- {0}" -f [string]$failure)) | Out-Null
      }
    }
    $lines.Add('') | Out-Null
  }
  Set-Content -LiteralPath $mdPath -Encoding UTF8 -Value ($lines -join "`r`n")
  Copy-Item -LiteralPath $mdPath -Destination $lastMdPath -Force

  if (Get-Command Write-RaymanEvent -ErrorAction SilentlyContinue) {
    Write-RaymanEvent -WorkspaceRoot $WorkspaceRoot -EventType 'prompts.eval' -Category 'prompts' -Payload $payload | Out-Null
  }

  return [pscustomobject]$payload
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$promptDir = Get-RaymanPromptTemplateDirectory -WorkspaceRoot $WorkspaceRoot
$templates = @(Get-RaymanPromptTemplates -WorkspaceRoot $WorkspaceRoot)

if ($Action -eq 'eval') {
  $evalResult = Invoke-RaymanPromptEval -WorkspaceRoot $WorkspaceRoot -Name $Name
  if ($Json) {
    $evalResult | ConvertTo-Json -Depth 14
  } else {
    Write-Host ("✅ [prompts] eval suites={0} passed={1} failed={2}" -f [int]$evalResult.suite_count, [int]$evalResult.passed_count, [int]$evalResult.failed_count) -ForegroundColor Green
    Write-Host ("🧾 [prompts] report={0}" -f [string]$evalResult.artifacts.json_path) -ForegroundColor DarkCyan
  }
  if ([int]$evalResult.failed_count -gt 0) {
    exit 7
  }
  exit 0
}

if (-not (Test-Path -LiteralPath $promptDir -PathType Container)) {
  Write-Host ("[prompts] missing directory: {0}" -f $promptDir) -ForegroundColor Yellow
  exit 2
}

if ($templates.Count -eq 0) {
  Write-Host ("[prompts] no templates found in: {0}" -f $promptDir) -ForegroundColor Yellow
  exit 2
}

if ($Action -eq 'list') {
  Write-Output "Rayman Prompt Templates:"
  foreach ($t in $templates) {
    Write-Output ("- {0}" -f $t.Name)
  }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Name)) {
  Write-Host "[prompts] --name is required for show/apply" -ForegroundColor Red
  exit 2
}

$template = Resolve-RaymanPromptTemplate -WorkspaceRoot $WorkspaceRoot -Name $Name
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

$result = Render-RaymanPromptTemplate -TemplateContent $content -WorkspaceRoot $WorkspaceRoot -Task $Task -AcceptanceCriteria $AcceptanceCriteria -Notes $Notes

$parent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $result -Encoding UTF8
Write-Host ("✅ [prompts] generated: {0}" -f $OutputPath) -ForegroundColor Green
