param(
    [Alias('Action')][ValidateSet('probe', 'ensure')][string]$BootstrapAction = 'probe',
    [Alias('WorkspaceRoot')][string]$BootstrapWorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [Alias('NoInstallDeps')][switch]$BootstrapNoInstallDeps,
    [Alias('Prewarm')][switch]$BootstrapPrewarm,
    [Alias('Quiet')][switch]$BootstrapQuiet,
    [Alias('Json')][switch]$BootstrapJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-MemoryBootstrapInfo([string]$Message) {
    if (-not $Quiet) {
        Write-Host ("✅ [Memory-Bootstrap] {0}" -f $Message) -ForegroundColor DarkCyan
    }
}

function Write-MemoryBootstrapWarn([string]$Message) {
    if (-not $Quiet) {
        Write-Host ("⚠️ [Memory-Bootstrap] {0}" -f $Message) -ForegroundColor Yellow
    }
}

function Get-RaymanMemoryRequirementsPath([string]$Root) {
    return (Join-Path $Root '.Rayman\scripts\memory\requirements.txt')
}

function Get-RaymanMemoryBackendPath([string]$Root) {
    return (Join-Path $Root '.Rayman\scripts\memory\manage_memory.py')
}

function Get-RaymanMemoryPythonCandidates {
    param(
        [string]$Root,
        [string]$MemoryPythonEnv,
        [string]$PythonEnv
    )

    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    function Add-Candidate {
        param([string]$Exe, [string[]]$Parameters = @(), [string]$Label = '')
        if ([string]::IsNullOrWhiteSpace($Exe)) { return }

        $resolvedExe = $Exe
        if (-not [System.IO.Path]::IsPathRooted($Exe)) {
            $cmd = Get-Command $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $cmd) { return }
            $resolvedExe = [string]$cmd.Source
        } elseif (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
            return
        }

        $argKey = if ($Parameters -and $Parameters.Count -gt 0) { ($Parameters -join ' ') } else { '' }
        $key = ("{0}|{1}" -f $resolvedExe.Trim().ToLowerInvariant(), $argKey.Trim().ToLowerInvariant())
        if (-not $seen.Add($key)) { return }

        if ([string]::IsNullOrWhiteSpace($Label)) {
            $Label = if ([string]::IsNullOrWhiteSpace($argKey)) { $resolvedExe } else { "$resolvedExe $argKey" }
        }

        $list.Add([pscustomobject]@{
            Exe = $resolvedExe
            Parameters = @($Parameters)
            Label = $Label
        }) | Out-Null
    }

    function Add-FromSpec {
        param([string]$Spec, [string]$Prefix)
        if ([string]::IsNullOrWhiteSpace($Spec)) { return }
        $parts = @([regex]::Split($Spec.Trim(), '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Length -eq 0) { return }
        $exe = [string]$parts[0]
        $parameters = @()
        if ($parts.Length -gt 1) { $parameters = @($parts[1..($parts.Length - 1)]) }
        $label = if ([string]::IsNullOrWhiteSpace($Prefix)) { $Spec } else { "$Prefix=$Spec" }
        Add-Candidate -Exe $exe -Parameters $parameters -Label $label
    }

    Add-FromSpec -Spec $MemoryPythonEnv -Prefix 'RAYMAN_MEMORY_PYTHON'
    Add-FromSpec -Spec $PythonEnv -Prefix 'RAYMAN_PYTHON'

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        Add-Candidate -Exe (Join-Path $Root '.venv\Scripts\python.exe') -Label '.venv/Scripts/python.exe'
        Add-Candidate -Exe (Join-Path $Root '.venv/bin/python') -Label '.venv/bin/python'
    }

    Add-Candidate -Exe 'python' -Label 'python'
    Add-Candidate -Exe 'python3' -Label 'python3'
    Add-Candidate -Exe 'py' -Parameters @('-3') -Label 'py -3'

    return $list.ToArray()
}

function Test-RaymanMemoryPython {
    param([pscustomobject]$Runtime)

    & $Runtime.Exe @($Runtime.Parameters + @('-c', 'import sqlite3, json, pathlib')) 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-RaymanMemoryDeps {
    param([pscustomobject]$Runtime)

    & $Runtime.Exe @($Runtime.Parameters + @('-c', 'import sentence_transformers')) 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-RaymanMemoryEmbeddingsEnabled {
    $raw = [string]$env:RAYMAN_MEMORY_ENABLE_EMBEDDINGS
    return ($raw.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on'))
}

function Invoke-RaymanMemoryBootstrap {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [string]$ScriptRoot = '',
        [switch]$SkipStatusProbe,
        [switch]$EnsureDeps,
        [switch]$NoInstallDeps,
        [switch]$Prewarm,
        [switch]$Quiet
    )

    $result = [pscustomobject]@{
        Success = $false
        WorkspaceRoot = ''
        PythonExe = ''
        PythonArgs = @()
        PythonLabel = ''
        PythonInvocation = ''
        RequirementsPath = ''
        BackendPath = ''
        DepsReady = $false
        InstalledDeps = $false
        SearchBackend = 'lexical'
        FallbackReason = ''
        StatusPath = ''
        StatusObject = $null
        Message = ''
        CheckedCandidates = @()
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $resolvedScriptRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
        (Resolve-Path -LiteralPath $ScriptRoot).Path
    } else {
        $resolvedRoot
    }
    $result.WorkspaceRoot = $resolvedRoot
    $result.RequirementsPath = Get-RaymanMemoryRequirementsPath -Root $resolvedScriptRoot
    $result.BackendPath = Get-RaymanMemoryBackendPath -Root $resolvedScriptRoot

    if (-not (Test-Path -LiteralPath $result.BackendPath -PathType Leaf)) {
        $result.Message = ("manage_memory.py 缺失: {0}" -f $result.BackendPath)
        return $result
    }

    $candidates = @(Get-RaymanMemoryPythonCandidates -Root $resolvedRoot -MemoryPythonEnv ([string]$env:RAYMAN_MEMORY_PYTHON) -PythonEnv ([string]$env:RAYMAN_PYTHON))
    $result.CheckedCandidates = @($candidates | ForEach-Object { [string]$_.Label })
    if ($candidates.Count -eq 0) {
        $result.Message = '未检测到可用 Python（已尝试: RAYMAN_MEMORY_PYTHON / RAYMAN_PYTHON / .venv / python / python3 / py -3）'
        return $result
    }

    $runtime = $null
    foreach ($candidate in $candidates) {
        if (Test-RaymanMemoryPython -Runtime $candidate) {
            $runtime = $candidate
            break
        }
    }
    if ($null -eq $runtime) {
        $result.Message = '已发现 Python 候选，但无法执行标准库探测'
        return $result
    }

    $result.PythonExe = [string]$runtime.Exe
    $result.PythonArgs = @([string[]]$runtime.Parameters)
    $result.PythonLabel = [string]$runtime.Label
    $result.PythonInvocation = if ($result.PythonArgs.Count -gt 0) { "$($result.PythonExe) $($result.PythonArgs -join ' ')" } else { $result.PythonExe }
    $embeddingsEnabled = Test-RaymanMemoryEmbeddingsEnabled
    $result.DepsReady = if ($embeddingsEnabled -or $EnsureDeps -or $Prewarm) {
        Test-RaymanMemoryDeps -Runtime $runtime
    } else {
        $false
    }

    if (-not $result.DepsReady -and $EnsureDeps -and -not $NoInstallDeps -and (Test-Path -LiteralPath $result.RequirementsPath -PathType Leaf)) {
        Write-MemoryBootstrapInfo ("正在安装 Agent Memory 依赖（{0}）..." -f $result.PythonLabel)
        & $runtime.Exe @($runtime.Parameters + @('-m', 'pip', 'install', '-r', $result.RequirementsPath, '-q'))
        if ($LASTEXITCODE -eq 0) {
            $result.InstalledDeps = $true
            $result.DepsReady = Test-RaymanMemoryDeps -Runtime $runtime
        }
    }

    if ($SkipStatusProbe) {
        $result.Success = $true
        $result.SearchBackend = if ($result.DepsReady) { 'embedding' } else { 'lexical' }
        $result.FallbackReason = if ($result.DepsReady) { 'ready' } elseif ($embeddingsEnabled) { 'embedding_deps_unavailable' } else { 'embedding_disabled' }
        $result.Message = if ($result.DepsReady) { 'Agent Memory Python runtime ready' } else { 'Agent Memory Python runtime ready (lexical fallback)' }
        return $result
    }

    $statusArgs = @(
        $runtime.Parameters +
        @(
            $result.BackendPath,
            'status',
            '--workspace-root', $resolvedRoot,
            '--json'
        ) +
        $(if ($Prewarm) { @('--prewarm') } else { @() })
    )
    $statusOutput = & $runtime.Exe @statusArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        $result.Message = ("manage_memory status 执行失败: {0}" -f (($statusOutput | ForEach-Object { [string]$_ }) -join ' '))
        return $result
    }

    $statusText = ($statusOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $statusObject = $null
    try {
        $statusObject = $statusText | ConvertFrom-Json -ErrorAction Stop
    } catch {}

    $result.Success = $true
    $result.StatusObject = $statusObject
    if ($null -ne $statusObject) {
        if ($null -ne $statusObject.PSObject.Properties['deps_ready']) {
            $result.DepsReady = [bool]$statusObject.deps_ready
        }
        if ($null -ne $statusObject.PSObject.Properties['status_path']) {
            $result.StatusPath = [string]$statusObject.status_path
        }
        if ($null -ne $statusObject.PSObject.Properties['search_backend']) {
            $result.SearchBackend = [string]$statusObject.search_backend
        }
        if ($null -ne $statusObject.PSObject.Properties['fallback_reason']) {
            $result.FallbackReason = [string]$statusObject.fallback_reason
        }
        if ($null -ne $statusObject.PSObject.Properties['message']) {
            $result.Message = [string]$statusObject.message
        }
    }

    if ([string]::IsNullOrWhiteSpace($result.Message)) {
        $result.Message = if ($result.DepsReady) { 'Agent Memory embedding 依赖已就绪' } else { 'Agent Memory 已降级为 lexical fallback' }
    }
    return $result
}

$isDotSourced = $MyInvocation.InvocationName -eq '.'
if ($isDotSourced) {
    return
}

$ensureDeps = ($BootstrapAction -eq 'ensure')
$bootstrap = Invoke-RaymanMemoryBootstrap -WorkspaceRoot $BootstrapWorkspaceRoot -EnsureDeps:$ensureDeps -NoInstallDeps:$BootstrapNoInstallDeps -Prewarm:$BootstrapPrewarm -Quiet:$BootstrapQuiet

if ($BootstrapJson) {
    $bootstrap | ConvertTo-Json -Depth 6
} else {
    if ($bootstrap.Success) {
        Write-MemoryBootstrapInfo ("ready: python={0}; depsReady={1}; backend={2}" -f $bootstrap.PythonLabel, $bootstrap.DepsReady, $bootstrap.SearchBackend)
    } else {
        Write-MemoryBootstrapWarn $bootstrap.Message
    }
}

if (-not $bootstrap.Success) {
    exit 2
}

exit 0
