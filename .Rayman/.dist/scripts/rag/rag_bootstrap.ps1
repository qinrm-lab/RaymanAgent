param(
    [ValidateSet('probe', 'ensure')][string]$Action = 'probe',
    [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path),
    [switch]$NoInstallDeps,
    [switch]$Quiet,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-RagBootstrapInfo([string]$Message) {
    if (-not $Quiet) {
        Write-Host ("✅ [RAG-Bootstrap] {0}" -f $Message) -ForegroundColor DarkCyan
    }
}

function Write-RagBootstrapWarn([string]$Message) {
    if (-not $Quiet) {
        Write-Host ("⚠️  [RAG-Bootstrap] {0}" -f $Message) -ForegroundColor Yellow
    }
}

function Get-RaymanRagRequirementsPath([string]$Root) {
    return (Join-Path $Root '.Rayman\scripts\rag\requirements.txt')
}

function Get-RaymanRagPythonCandidates {
    param(
        [string]$Root,
        [string]$RagPythonEnv,
        [string]$PythonEnv
    )

    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    function Add-Candidate {
        param([string]$Exe, [string[]]$Args = @(), [string]$Label = '')
        if ([string]::IsNullOrWhiteSpace($Exe)) { return }

        $cmd = Get-Command $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) { return }

        $argKey = if ($Args -and $Args.Count -gt 0) { ($Args -join ' ') } else { '' }
        $key = ("{0}|{1}" -f $Exe.Trim().ToLowerInvariant(), $argKey.Trim().ToLowerInvariant())
        if (-not $seen.Add($key)) { return }

        if ([string]::IsNullOrWhiteSpace($Label)) {
            $Label = if ([string]::IsNullOrWhiteSpace($argKey)) { $Exe } else { "$Exe $argKey" }
        }

        $list.Add([pscustomobject]@{
            Exe = $Exe
            Args = @($Args)
            Label = $Label
        }) | Out-Null
    }

    function Add-FromSpec {
        param([string]$Spec, [string]$Prefix)
        if ([string]::IsNullOrWhiteSpace($Spec)) { return }

        $parts = @([regex]::Split($Spec.Trim(), '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Length -eq 0) { return }

        $exe = [string]$parts[0]
        $args = @()
        if ($parts.Length -gt 1) { $args = @($parts[1..($parts.Length - 1)]) }

        $label = if ([string]::IsNullOrWhiteSpace($Prefix)) { $Spec } else { "$Prefix=$Spec" }
        Add-Candidate -Exe $exe -Args $args -Label $label
    }

    Add-FromSpec -Spec $RagPythonEnv -Prefix 'RAYMAN_RAG_PYTHON'
    Add-FromSpec -Spec $PythonEnv -Prefix 'RAYMAN_PYTHON'

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        Add-Candidate -Exe (Join-Path $Root '.venv\Scripts\python.exe') -Label '.venv/Scripts/python.exe'
        Add-Candidate -Exe (Join-Path $Root '.venv/bin/python') -Label '.venv/bin/python'
    }

    Add-Candidate -Exe 'python' -Label 'python'
    Add-Candidate -Exe 'python3' -Label 'python3'
    Add-Candidate -Exe 'py' -Args @('-3') -Label 'py -3'

    return $list.ToArray()
}

function Test-RaymanRagDeps {
    param([pscustomobject]$Runtime)

    & $Runtime.Exe @($Runtime.Args + @('-c', 'import chromadb, sentence_transformers, langchain_text_splitters')) 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-RaymanRagBootstrap {
    [CmdletBinding()]
    param(
        [string]$WorkspaceRoot,
        [switch]$EnsureDeps,
        [switch]$NoInstallDeps,
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
        DepsReady = $false
        InstalledDeps = $false
        Message = ''
        CheckedCandidates = @()
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $result.WorkspaceRoot = $resolvedRoot

    $requirementsPath = Get-RaymanRagRequirementsPath -Root $resolvedRoot
    $result.RequirementsPath = $requirementsPath

    $candidates = @(Get-RaymanRagPythonCandidates -Root $resolvedRoot -RagPythonEnv ([string]$env:RAYMAN_RAG_PYTHON) -PythonEnv ([string]$env:RAYMAN_PYTHON))
    $result.CheckedCandidates = @($candidates | ForEach-Object { [string]$_.Label })

    if ($candidates.Count -eq 0) {
        $result.Message = '未检测到可用 Python（已尝试: RAYMAN_RAG_PYTHON / RAYMAN_PYTHON / .venv/Scripts/python.exe / .venv/bin/python / python / python3 / py -3）'
        return $result
    }

    $runtime = $candidates[0]
    $result.PythonExe = [string]$runtime.Exe
    $result.PythonArgs = @([string[]]$runtime.Args)
    $result.PythonLabel = [string]$runtime.Label
    $result.PythonInvocation = if ($result.PythonArgs.Count -gt 0) { "$($result.PythonExe) $($result.PythonArgs -join ' ')" } else { $result.PythonExe }

    if (Test-RaymanRagDeps -Runtime $runtime) {
        $result.Success = $true
        $result.DepsReady = $true
        $result.Message = 'RAG 依赖已就绪'
        return $result
    }

    if (-not $EnsureDeps -or $NoInstallDeps) {
        $result.Message = ("RAG 依赖未就绪（解释器={0}）" -f $result.PythonLabel)
        return $result
    }

    if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
        $result.Message = ("requirements.txt 缺失: {0}" -f $requirementsPath)
        return $result
    }

    Write-RagBootstrapInfo ("正在安装 RAG 依赖（{0}）..." -f $result.PythonLabel)
    & $runtime.Exe @($runtime.Args + @('-m', 'pip', 'install', '-r', $requirementsPath, '-q'))
    if ($LASTEXITCODE -ne 0) {
        $result.Message = ("依赖安装失败（解释器={0}）" -f $result.PythonLabel)
        return $result
    }

    if (Test-RaymanRagDeps -Runtime $runtime) {
        $result.Success = $true
        $result.DepsReady = $true
        $result.InstalledDeps = $true
        $result.Message = 'RAG 依赖安装并验证成功'
        return $result
    }

    $result.Message = ("依赖安装后验证失败（解释器={0}）" -f $result.PythonLabel)
    return $result
}

$isDotSourced = $MyInvocation.InvocationName -eq '.'
if ($isDotSourced) {
    return
}

$ensureDeps = ($Action -eq 'ensure')
$bootstrap = Invoke-RaymanRagBootstrap -WorkspaceRoot $WorkspaceRoot -EnsureDeps:$ensureDeps -NoInstallDeps:$NoInstallDeps -Quiet:$Quiet

if ($Json) {
    $bootstrap | ConvertTo-Json -Depth 5
} else {
    if ($bootstrap.Success) {
        Write-RagBootstrapInfo ("ready: python={0}; depsReady={1}; installedDeps={2}" -f $bootstrap.PythonLabel, $bootstrap.DepsReady, $bootstrap.InstalledDeps)
    } else {
        Write-RagBootstrapWarn $bootstrap.Message
    }
}

if (-not $bootstrap.Success) {
    exit 2
}

exit 0
