param(
  [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RaymanDotNetWorkspacePath {
  param(
    [string]$Path,
    [switch]$AllowMissing
  )

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return '' }
  try {
    if (-not $AllowMissing) {
      return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
  } catch {}

  try {
    return [System.IO.Path]::GetFullPath([string]$Path)
  } catch {
    return [string]$Path
  }
}

function Test-RaymanDotNetWorkspacePathsEqual {
  param(
    [string]$Left,
    [string]$Right
  )

  $leftResolved = Resolve-RaymanDotNetWorkspacePath -Path $Left -AllowMissing
  $rightResolved = Resolve-RaymanDotNetWorkspacePath -Path $Right -AllowMissing
  if ([string]::IsNullOrWhiteSpace([string]$leftResolved) -or [string]::IsNullOrWhiteSpace([string]$rightResolved)) {
    return $false
  }

  return $leftResolved.TrimEnd('\', '/').Equals($rightResolved.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RaymanDotNetWorkspaceRelativePath {
  param(
    [string]$BaseRoot,
    [string]$Path
  )

  $resolvedPath = Resolve-RaymanDotNetWorkspacePath -Path $Path -AllowMissing
  if ([string]::IsNullOrWhiteSpace([string]$resolvedPath)) {
    return ''
  }

  if ([string]::IsNullOrWhiteSpace([string]$BaseRoot)) {
    return ($resolvedPath -replace '/', '\')
  }

  $resolvedBaseRoot = Resolve-RaymanDotNetWorkspacePath -Path $BaseRoot -AllowMissing
  if ([string]::IsNullOrWhiteSpace([string]$resolvedBaseRoot)) {
    return ($resolvedPath -replace '/', '\')
  }

  $normalizedPath = ($resolvedPath -replace '/', '\')
  $normalizedBaseRoot = ($resolvedBaseRoot -replace '/', '\').TrimEnd('\')
  if ($normalizedPath.Equals($normalizedBaseRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ''
  }

  $prefix = $normalizedBaseRoot + '\'
  if ($normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $normalizedPath.Substring($prefix.Length)
  }

  return $normalizedPath
}

function Test-RaymanDotNetWorkspacePathExcluded {
  param(
    [string]$Path,
    [string]$BaseRoot = '',
    [string[]]$ExcludedSegments = @('.git', '.rayman', '.venv', 'node_modules', 'bin', 'obj')
  )

  if ([string]::IsNullOrWhiteSpace([string]$Path)) { return $true }

  $relativePath = (Get-RaymanDotNetWorkspaceRelativePath -BaseRoot $BaseRoot -Path $Path).Trim('\', '/')
  if ([string]::IsNullOrWhiteSpace([string]$relativePath)) {
    return $false
  }

  $segments = @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).ToLowerInvariant() })
  foreach ($segment in @($ExcludedSegments | ForEach-Object { ([string]$_).ToLowerInvariant() })) {
    if ($segments -contains $segment) {
      return $true
    }
  }

  return $false
}

function Get-RaymanDotNetTargetFrameworksFromText {
  param([string]$ProjectText)

  $frameworks = New-Object 'System.Collections.Generic.List[string]'
  if ([string]::IsNullOrWhiteSpace([string]$ProjectText)) {
    return @()
  }

  foreach ($match in [regex]::Matches($ProjectText, '<TargetFrameworks?\b[^>]*>\s*([^<]+?)\s*</TargetFrameworks?>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $raw = [string]$match.Groups[1].Value
    foreach ($part in ($raw -split ';')) {
      $token = [string]$part
      if ([string]::IsNullOrWhiteSpace([string]$token)) { continue }
      $token = $token.Trim()
      if ($token -match '\$\(') { continue }
      if (-not $frameworks.Contains($token)) {
        $frameworks.Add($token) | Out-Null
      }
    }
  }

  return @($frameworks.ToArray())
}

function Get-RaymanDotNetTargetFrameworksFromProjectPath {
  param([string]$ProjectPath)

  if ([string]::IsNullOrWhiteSpace([string]$ProjectPath) -or -not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
    return @()
  }

  try {
    $raw = Get-Content -LiteralPath $ProjectPath -Raw -Encoding UTF8
    return @(Get-RaymanDotNetTargetFrameworksFromText -ProjectText $raw)
  } catch {
    return @()
  }
}

function Get-RaymanDotNetProjectText {
  param([string]$ProjectPath)

  if ([string]::IsNullOrWhiteSpace([string]$ProjectPath) -or -not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
    return ''
  }

  try {
    return (Get-Content -LiteralPath $ProjectPath -Raw -Encoding UTF8)
  } catch {
    return ''
  }
}

function Get-RaymanDotNetProjectOutputTypesFromText {
  param([string]$ProjectText)

  $outputTypes = New-Object 'System.Collections.Generic.List[string]'
  if ([string]::IsNullOrWhiteSpace([string]$ProjectText)) {
    return @()
  }

  foreach ($match in [regex]::Matches($ProjectText, '<OutputType\b[^>]*>\s*([^<]+?)\s*</OutputType>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $value = [string]$match.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
    $normalized = $value.Trim()
    if (-not $outputTypes.Contains($normalized)) {
      $outputTypes.Add($normalized) | Out-Null
    }
  }

  return @($outputTypes.ToArray())
}

function Get-RaymanDotNetProjectSdkNamesFromText {
  param([string]$ProjectText)

  $sdkNames = New-Object 'System.Collections.Generic.List[string]'
  if ([string]::IsNullOrWhiteSpace([string]$ProjectText)) {
    return @()
  }

  foreach ($match in [regex]::Matches($ProjectText, '\bSdk\s*=\s*["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    foreach ($part in ([string]$match.Groups[1].Value -split ';')) {
      $sdkName = [string]$part
      if ([string]::IsNullOrWhiteSpace([string]$sdkName)) { continue }
      $normalized = $sdkName.Trim()
      if (-not $sdkNames.Contains($normalized)) {
        $sdkNames.Add($normalized) | Out-Null
      }
    }
  }

  return @($sdkNames.ToArray())
}

function Test-RaymanDotNetProjectLaunchableFromText {
  param([string]$ProjectText)

  if ([string]::IsNullOrWhiteSpace([string]$ProjectText)) {
    return $false
  }

  $normalizedText = $ProjectText.ToLowerInvariant()
  if ($normalizedText -match '<istestproject>\s*true\s*</istestproject>') {
    return $false
  }

  $launchableOutputTypes = @('exe', 'winexe', 'appcontainerexe')
  $outputTypes = @(Get-RaymanDotNetProjectOutputTypesFromText -ProjectText $ProjectText | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique)
  if ($outputTypes.Count -gt 0) {
    foreach ($outputType in @($outputTypes)) {
      if ($launchableOutputTypes -contains [string]$outputType) {
        return $true
      }
    }
    return $false
  }

  $launchableSdks = @('microsoft.net.sdk.web', 'microsoft.net.sdk.worker')
  foreach ($sdkName in @(Get-RaymanDotNetProjectSdkNamesFromText -ProjectText $ProjectText | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique)) {
    if ($launchableSdks -contains [string]$sdkName) {
      return $true
    }
  }

  if ($normalizedText -match '<usemaui>\s*true\s*</usemaui>') { return $true }
  if ($normalizedText -match '<usewpf>\s*true\s*</usewpf>') { return $true }
  if ($normalizedText -match '<usewindowsforms>\s*true\s*</usewindowsforms>') { return $true }
  if ($normalizedText -match '<usewinui>\s*true\s*</usewinui>') { return $true }
  if ($normalizedText.Contains('microsoft.windowsappsdk')) { return $true }

  return $false
}

function Test-RaymanDotNetProjectLaunchable {
  param([string]$ProjectPath)

  $projectText = Get-RaymanDotNetProjectText -ProjectPath $ProjectPath
  return (Test-RaymanDotNetProjectLaunchableFromText -ProjectText $projectText)
}

function Get-RaymanDotNetRootSolutionPaths {
  param([string]$WorkspaceRoot)

  $resolvedRoot = Resolve-RaymanDotNetWorkspacePath -Path $WorkspaceRoot
  if ([string]::IsNullOrWhiteSpace([string]$resolvedRoot) -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    return @()
  }

  $slnx = @(Get-ChildItem -LiteralPath $resolvedRoot -File -Filter '*.slnx' -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($slnx.Count -gt 0) {
    return @($slnx | ForEach-Object { (Resolve-RaymanDotNetWorkspacePath -Path $_.FullName) })
  }

  $sln = @(Get-ChildItem -LiteralPath $resolvedRoot -File -Filter '*.sln' -ErrorAction SilentlyContinue | Sort-Object Name)
  return @($sln | ForEach-Object { (Resolve-RaymanDotNetWorkspacePath -Path $_.FullName) })
}

function Get-RaymanDotNetSolutionProjectRelativePaths {
  param([string]$SolutionPath)

  $resolvedSolutionPath = Resolve-RaymanDotNetWorkspacePath -Path $SolutionPath
  if ([string]::IsNullOrWhiteSpace([string]$resolvedSolutionPath) -or -not (Test-Path -LiteralPath $resolvedSolutionPath -PathType Leaf)) {
    return @()
  }

  $paths = New-Object 'System.Collections.Generic.List[string]'
  $extension = [System.IO.Path]::GetExtension($resolvedSolutionPath).ToLowerInvariant()

  switch ($extension) {
    '.slnx' {
      try {
        [xml]$xml = Get-Content -LiteralPath $resolvedSolutionPath -Raw -Encoding UTF8
        $projectNodes = @()
        if ($null -ne $xml.Solution) {
          $projectNodes = @($xml.Solution.Project)
        }
        foreach ($node in @($projectNodes)) {
          if ($null -eq $node) { continue }
          $candidate = ''
          if ($node -is [System.Xml.XmlElement] -and $node.HasAttribute('Path')) {
            $candidate = [string]$node.GetAttribute('Path')
          } elseif ($node.PSObject.Properties['Path']) {
            $candidate = [string]$node.Path
          }
          $candidate = ($candidate -replace '/', '\').Trim()
          if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
          if (-not $paths.Contains($candidate)) {
            $paths.Add($candidate) | Out-Null
          }
        }
      } catch {}
      break
    }
    '.sln' {
      try {
        foreach ($line in @(Get-Content -LiteralPath $resolvedSolutionPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
          $text = [string]$line
          if ($text -notmatch '^\s*Project\(".*?"\)\s*=\s*".*?",\s*"(.*?)",\s*".*?"') {
            continue
          }
          $candidate = ([string]$matches[1] -replace '/', '\').Trim()
          if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
          if (-not $paths.Contains($candidate)) {
            $paths.Add($candidate) | Out-Null
          }
        }
      } catch {}
      break
    }
  }

  return @($paths.ToArray())
}

function Resolve-RaymanDotNetSolutionProjectPath {
  param(
    [string]$ProjectRelativePath,
    [string]$WorkspaceRoot,
    [string]$ExecutionRoot = ''
  )

  if ([string]::IsNullOrWhiteSpace([string]$ProjectRelativePath)) {
    return ''
  }

  if ([System.IO.Path]::IsPathRooted([string]$ProjectRelativePath)) {
    $resolvedAbsolute = Resolve-RaymanDotNetWorkspacePath -Path $ProjectRelativePath -AllowMissing
    if (-not [string]::IsNullOrWhiteSpace([string]$resolvedAbsolute) -and (Test-Path -LiteralPath $resolvedAbsolute -PathType Leaf)) {
      return $resolvedAbsolute
    }
    return ''
  }

  $normalizedRelativePath = ([string]$ProjectRelativePath).Trim().Trim('"').Replace('/', '\').TrimStart('\', '/')
  if ([string]::IsNullOrWhiteSpace([string]$normalizedRelativePath)) {
    return ''
  }

  $resolvedWorkspaceRoot = Resolve-RaymanDotNetWorkspacePath -Path $WorkspaceRoot
  if ([string]::IsNullOrWhiteSpace([string]$resolvedWorkspaceRoot)) {
    return ''
  }

  $resolvedExecutionRoot = if ([string]::IsNullOrWhiteSpace([string]$ExecutionRoot)) {
    $resolvedWorkspaceRoot
  } else {
    Resolve-RaymanDotNetWorkspacePath -Path $ExecutionRoot -AllowMissing
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$resolvedExecutionRoot)) {
    $executionCandidate = Join-Path $resolvedExecutionRoot $normalizedRelativePath
    if (Test-Path -LiteralPath $executionCandidate -PathType Leaf) {
      return (Resolve-RaymanDotNetWorkspacePath -Path $executionCandidate)
    }
    if (-not (Test-RaymanDotNetWorkspacePathsEqual -Left $resolvedWorkspaceRoot -Right $resolvedExecutionRoot)) {
      return ''
    }
  }

  $workspaceCandidate = Join-Path $resolvedWorkspaceRoot $normalizedRelativePath
  if (Test-Path -LiteralPath $workspaceCandidate -PathType Leaf) {
    return (Resolve-RaymanDotNetWorkspacePath -Path $workspaceCandidate)
  }

  return ''
}

function Get-RaymanDotNetProjectFiles {
  param(
    [string]$Root,
    [string[]]$ProjectExtensions = @('.csproj', '.fsproj', '.vbproj'),
    [string[]]$ExcludedSegments = @('.git', '.rayman', '.venv', 'node_modules', 'bin', 'obj'),
    [string[]]$ExcludedRelativeRoots = @()
  )

  $resolvedRoot = Resolve-RaymanDotNetWorkspacePath -Path $Root
  if ([string]::IsNullOrWhiteSpace([string]$resolvedRoot) -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    return @()
  }

  $extensionLookup = @{}
  foreach ($extension in @($ProjectExtensions)) {
    $normalizedExtension = ([string]$extension).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace([string]$normalizedExtension)) {
      $extensionLookup[$normalizedExtension] = $true
    }
  }
  if ($extensionLookup.Count -eq 0) {
    return @()
  }

  $excludedPrefixes = @($ExcludedRelativeRoots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim('\', '/').Replace('\', '/').ToLowerInvariant() } | Select-Object -Unique)
  $pending = New-Object 'System.Collections.Generic.Stack[string]'
  $files = New-Object 'System.Collections.Generic.List[string]'
  $pending.Push($resolvedRoot)

  while ($pending.Count -gt 0) {
    $current = [string]$pending.Pop()
    foreach ($directory in @(Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
      $relativePath = (Get-RaymanDotNetWorkspaceRelativePath -BaseRoot $resolvedRoot -Path $directory.FullName).Trim('\', '/')
      $normalizedRelativePath = $relativePath.Replace('\', '/').ToLowerInvariant()
      $skipDirectory = $false
      foreach ($excludedPrefix in @($excludedPrefixes)) {
        if ([string]::IsNullOrWhiteSpace([string]$excludedPrefix)) { continue }
        if ($normalizedRelativePath.Equals($excludedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $normalizedRelativePath.StartsWith($excludedPrefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
          $skipDirectory = $true
          break
        }
      }
      if ($skipDirectory) { continue }
      if (Test-RaymanDotNetWorkspacePathExcluded -Path $directory.FullName -BaseRoot $resolvedRoot -ExcludedSegments $ExcludedSegments) {
        continue
      }
      $pending.Push([string]$directory.FullName)
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $current -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
      if (Test-RaymanDotNetWorkspacePathExcluded -Path $file.FullName -BaseRoot $resolvedRoot -ExcludedSegments $ExcludedSegments) {
        continue
      }
      $extension = [System.IO.Path]::GetExtension([string]$file.Name).ToLowerInvariant()
      if (-not $extensionLookup.ContainsKey($extension)) {
        continue
      }
      $files.Add((Resolve-RaymanDotNetWorkspacePath -Path $file.FullName)) | Out-Null
    }
  }

  return @($files.ToArray() | Select-Object -Unique | Sort-Object)
}
