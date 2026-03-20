param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
  [switch]$Force,
  [switch]$AllowSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\common.ps1')
. (Join-Path $PSScriptRoot 'project_gate.lib.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$workspaceKind = Get-RaymanWorkspaceKind -WorkspaceRoot $WorkspaceRoot
if ($workspaceKind -eq 'source' -and -not $AllowSource) {
  Write-Host '[project-workflows] source workspace detected; skip managed consumer workflow generation.' -ForegroundColor Yellow
  exit 0
}

$configInfo = Read-RaymanProjectConfig -WorkspaceRoot $WorkspaceRoot
$configPath = Get-RaymanProjectConfigPath -WorkspaceRoot $WorkspaceRoot
if (-not $configInfo.exists) {
  $configJson = ConvertTo-RaymanProjectConfigJson -WorkspaceRoot $WorkspaceRoot
  Set-Content -LiteralPath $configPath -Value $configJson -Encoding UTF8
  $configInfo = Read-RaymanProjectConfig -WorkspaceRoot $WorkspaceRoot
}

if (-not $configInfo.valid) {
  throw ("project config parse failed: {0}" -f [string]$configInfo.parse_error)
}

$config = $configInfo.config
$displayName = Get-RaymanProjectDisplayName -WorkspaceRoot $WorkspaceRoot -Config $config
$artifactPrefix = (($displayName.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-') -replace '^-+', '' -replace '-+$', '')
if ([string]::IsNullOrWhiteSpace($artifactPrefix)) {
  $artifactPrefix = 'rayman-project'
}

function Get-TemplateContent {
  param([ValidateSet('fast', 'browser', 'full')][string]$Lane)

  $templatePath = Get-RaymanProjectWorkflowTemplatePath -WorkspaceRoot $WorkspaceRoot -Lane $Lane
  if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw ("workflow template missing: {0}" -f $templatePath)
  }
  return (Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8)
}

function Write-ManagedWorkflow {
  param(
    [ValidateSet('fast', 'browser', 'full')][string]$Lane,
    [string]$Content
  )

  $targetPath = Get-RaymanProjectWorkflowTargetPath -WorkspaceRoot $WorkspaceRoot -Lane $Lane
  $parent = Split-Path -Parent $targetPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  $allowWrite = $true
  if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and -not $Force) {
    $existing = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
    if ($existing -notmatch '(?i)Rayman managed workflow') {
      $allowWrite = $false
      Write-Host ("[project-workflows] skip unmanaged workflow: {0}" -f $targetPath) -ForegroundColor Yellow
    }
  }

  if ($allowWrite) {
    Set-Content -LiteralPath $targetPath -Value $Content -Encoding UTF8
    Write-Host ("[project-workflows] wrote {0}" -f (Get-DisplayRelativePath -BasePath $WorkspaceRoot -FullPath $targetPath)) -ForegroundColor Green
  }
}

function Get-WindowsFastJobBlock {
  if (-not [bool]$config.enable_windows) { return '' }
  return @"

  fast-gate-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.x"

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install Rayman fast gate dependencies
        shell: pwsh
        run: |
          python -m pip install --upgrade pip jsonschema

      - name: Run Rayman fast gate
        shell: pwsh
        run: |
          ./.Rayman/rayman.ps1 fast-gate

      - name: Upload Rayman fast gate artifacts
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: ${artifactPrefix}-fast-gate-windows
          path: |
            .Rayman/runtime/project_gates/**
            .Rayman/runtime/*.json
            .Rayman/logs/**
"@
}

function Get-WindowsFullJobBlock {
  if (-not [bool]$config.enable_windows) { return '' }
  return @"

  full-gate-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.x"

      - uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install Rayman full gate dependencies
        shell: pwsh
        run: |
          python -m pip install --upgrade pip jsonschema

      - name: Run Rayman full gate
        shell: pwsh
        run: |
          ./.Rayman/rayman.ps1 full-gate

      - name: Upload Rayman full gate artifacts
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: ${artifactPrefix}-full-gate-windows
          path: |
            .Rayman/runtime/project_gates/**
            .Rayman/runtime/*.json
            .Rayman/state/**
            .Rayman/logs/**
"@
}

function Render-Workflow {
  param([ValidateSet('fast', 'browser', 'full')][string]$Lane)

  $template = Get-TemplateContent -Lane $Lane
  $pathFilters = switch ($Lane) {
    'fast' { @($config.path_filters.fast) }
    'browser' { @($config.path_filters.browser) }
    default { @($config.path_filters.full) }
  }

  $replacements = [ordered]@{
    '{{ARTIFACT_PREFIX}}' = $artifactPrefix
    '{{FAST_PATHS}}' = (Format-RaymanWorkflowYamlList -Values @($config.path_filters.fast) -Indent 6)
    '{{BROWSER_PATHS}}' = (Format-RaymanWorkflowYamlList -Values @($config.path_filters.browser) -Indent 6)
    '{{FULL_PATHS}}' = (Format-RaymanWorkflowYamlList -Values @($config.path_filters.full) -Indent 6)
    '{{WINDOWS_FAST_JOB}}' = (Get-WindowsFastJobBlock)
    '{{WINDOWS_FULL_JOB}}' = (Get-WindowsFullJobBlock)
  }

  $rendered = $template
  foreach ($entry in $replacements.GetEnumerator()) {
    $rendered = $rendered.Replace([string]$entry.Key, [string]$entry.Value)
  }
  return $rendered
}

foreach ($lane in @('fast', 'browser', 'full')) {
  Write-ManagedWorkflow -Lane $lane -Content (Render-Workflow -Lane $lane)
}
