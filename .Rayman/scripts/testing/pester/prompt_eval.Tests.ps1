Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  $script:PromptsScript = Join-Path $script:WorkspaceRoot '.Rayman\scripts\agents\prompts_catalog.ps1'
}

function script:New-PromptEvalTestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman_prompt_eval_' + [Guid]::NewGuid().ToString('N'))
  foreach ($path in @(
      $root,
      (Join-Path $root '.github\prompts'),
      (Join-Path $root '.Rayman\config')
    )) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
  }

  Set-Content -LiteralPath (Join-Path $root '.github\prompts\review.initial.prompt.md') -Encoding UTF8 -Value @'
description: Prompt eval test

Task: {{TASK}}
Acceptance: {{ACCEPTANCE_CRITERIA}}
Notes: {{NOTES}}
'@
  Set-Content -LiteralPath (Join-Path $root '.Rayman\config\prompt_eval_suites.json') -Encoding UTF8 -Value @'
{
  "schema": "rayman.prompt_eval_suites.v1",
  "suites": [
    {
      "id": "review-suite",
      "description": "Evaluate a single prompt rendering path.",
      "prompts": ["review.initial.prompt.md"],
      "cases": [
        {
          "id": "rollback-case",
          "task": "Investigate rollback drift",
          "acceptance_criteria": "Acceptance mentions rollback parity",
          "notes": "No hosted optimizer required.",
          "expected_contains": [
            "Investigate rollback drift",
            "Acceptance mentions rollback parity"
          ],
          "forbidden_contains": [
            "{{TASK}}",
            "{{ACCEPTANCE_CRITERIA}}",
            "{{NOTES}}"
          ]
        }
      ]
    }
  ]
}
'@

  return $root
}

function script:Get-PromptEvalEventTypes {
  param([string]$Root)

  $eventDir = Join-Path $Root '.Rayman\runtime\events'
  if (-not (Test-Path -LiteralPath $eventDir -PathType Container)) {
    return @()
  }

  $types = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-ChildItem -LiteralPath $eventDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
    foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
      try {
        $event = [string]$line | ConvertFrom-Json -ErrorAction Stop
        if ($event.PSObject.Properties['event_type']) {
          $types.Add([string]$event.event_type) | Out-Null
        }
      } catch {}
    }
  }

  return @($types.ToArray())
}

Describe 'prompt eval' {
  It 'runs eval suites, writes runtime reports, and emits events' {
    $root = New-PromptEvalTestRoot
    try {
      $listOutput = @(& $script:PromptsScript -WorkspaceRoot $root -Action list)
      $result = & $script:PromptsScript -WorkspaceRoot $root -Action eval -Json | ConvertFrom-Json

      (($listOutput | ForEach-Object { [string]$_ }) -join "`n") | Should -Match 'review\.initial\.prompt\.md'
      $result.schema | Should -Be 'rayman.prompt_eval.v1'
      [int]$result.suite_count | Should -Be 1
      [int]$result.failed_count | Should -Be 0
      [int]$result.result_count | Should -Be 1
      Test-Path -LiteralPath ([string]$result.artifacts.json_path) -PathType Leaf | Should -Be $true
      Test-Path -LiteralPath ([string]$result.artifacts.markdown_path) -PathType Leaf | Should -Be $true
      Test-Path -LiteralPath ([string]$result.artifacts.last_json_path) -PathType Leaf | Should -Be $true
      Test-Path -LiteralPath ([string]$result.artifacts.last_markdown_path) -PathType Leaf | Should -Be $true
      (@(Get-PromptEvalEventTypes -Root $root) -contains 'prompts.eval') | Should -Be $true
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
