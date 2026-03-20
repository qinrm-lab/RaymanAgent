Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ComparablePathText {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $candidate = [string]$PathValue
  if ($candidate.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $candidate = $candidate.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  $candidate = $candidate.Trim().Trim('"').Trim("'")
  if ($candidate -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
    $drive = ([string]$Matches[1]).ToUpperInvariant()
    $rest = if ($Matches.Count -gt 2) { [string]$Matches[2] } else { '' }
    if ([string]::IsNullOrWhiteSpace($rest)) {
      $candidate = ('{0}:\' -f $drive)
    } else {
      $candidate = ('{0}:\{1}' -f $drive, ($rest -replace '/', '\'))
    }
  }
  if ($candidate -match '^[A-Za-z]:[\\/]') {
    return $candidate
  }
  try {
    return [System.IO.Path]::GetFullPath($candidate)
  } catch {
    return $candidate
  }
}

function Get-PathComparisonValue {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  $full = Resolve-ComparablePathText -PathValue $PathValue
  return ($full.TrimEnd('\', '/') -replace '\\', '/').ToLowerInvariant()
}

function Test-AbsolutePathText {
  param(
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
  if ($PathValue -match '^[A-Za-z]:[\\/]') { return $true }
  try {
    return [System.IO.Path]::IsPathRooted($PathValue)
  } catch {
    return $false
  }
}

function Get-DisplayRelativePath {
  param(
    [string]$BasePath,
    [string]$FullPath
  )

  if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
  $baseRaw = [string]$BasePath
  $fullRaw = [string]$FullPath
  if ($baseRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $baseRaw = $baseRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  if ($fullRaw.StartsWith('Microsoft.PowerShell.Core\FileSystem::', [System.StringComparison]::OrdinalIgnoreCase)) {
    $fullRaw = $fullRaw.Substring('Microsoft.PowerShell.Core\FileSystem::'.Length)
  }
  $baseFull = (Resolve-ComparablePathText -PathValue $baseRaw).TrimEnd('\', '/')
  $full = Resolve-ComparablePathText -PathValue $fullRaw
  $baseNorm = Get-PathComparisonValue -PathValue $baseFull
  $fullNorm = Get-PathComparisonValue -PathValue $full
  if ($fullNorm.StartsWith($baseNorm + '/')) {
    return ($full.Substring($baseFull.Length).TrimStart('\', '/') -replace '\\', '/')
  }
  return ($full -replace '\\', '/')
}

function Get-VersionTokenFromName {
  param(
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
  $match = [regex]::Match($Name, '(?i)\bv\d+\b')
  if (-not $match.Success) { return '' }
  return $match.Value.ToLowerInvariant()
}

function Get-ReportWorkspaceRoot {
  param(
    [object]$Report
  )

  if ($null -eq $Report) { return '' }
  $prop = $Report.PSObject.Properties['workspace_root']
  if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
    return ''
  }
  return [string]$prop.Value
}

function Test-ReportWorkspaceRootMatch {
  param(
    [object]$Report,
    [string]$WorkspaceRoot
  )

  $reportRoot = Get-ReportWorkspaceRoot -Report $Report
  if ([string]::IsNullOrWhiteSpace($reportRoot)) {
    return $true
  }
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    return $false
  }
  return ((Get-PathComparisonValue -PathValue $reportRoot) -eq (Get-PathComparisonValue -PathValue $WorkspaceRoot))
}

function Get-TestLaneReportEvaluation {
  param(
    [object]$Report,
    [string]$ExpectedSchema,
    [string]$SuccessProperty = 'success',
    [string]$OverallProperty = '',
    [string]$WorkspaceRoot = ''
  )

  if ($null -eq $Report) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = 'report parse failed'
    }
  }

  $schemaText = ''
  if ($null -ne $Report.PSObject.Properties['schema'] -and $null -ne $Report.schema) {
    $schemaText = [string]$Report.schema
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSchema) -and $schemaText -ne $ExpectedSchema) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = ("schema mismatch: actual={0}, expected={1}" -f $schemaText, $ExpectedSchema)
    }
  }

  if (-not (Test-ReportWorkspaceRootMatch -Report $Report -WorkspaceRoot $WorkspaceRoot)) {
    $reportRoot = Get-ReportWorkspaceRoot -Report $Report
    return [pscustomobject]@{
      status = 'STALE'
      detail = ("stale_report_workspace_mismatch:{0}" -f $reportRoot)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($OverallProperty)) {
    $overallProp = $Report.PSObject.Properties[$OverallProperty]
    if ($null -eq $overallProp -or [string]::IsNullOrWhiteSpace([string]$overallProp.Value)) {
      return [pscustomobject]@{
        status = 'INVALID'
        detail = ("missing overall property: {0}" -f $OverallProperty)
      }
    }

    $overallText = ([string]$overallProp.Value).Trim().ToUpperInvariant()
    if ($overallText -notin @('PASS', 'WARN', 'FAIL')) {
      return [pscustomobject]@{
        status = 'INVALID'
        detail = ("invalid overall value: {0}" -f [string]$overallProp.Value)
      }
    }

    return [pscustomobject]@{
      status = $overallText
      detail = ("overall={0}" -f $overallText)
    }
  }

  if ([string]::IsNullOrWhiteSpace($SuccessProperty)) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = 'no evaluation property configured'
    }
  }

  $successProp = $Report.PSObject.Properties[$SuccessProperty]
  if ($null -eq $successProp) {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = ("missing success property: {0}" -f $SuccessProperty)
    }
  }

  try {
    $successValue = [bool][System.Management.Automation.LanguagePrimitives]::ConvertTo($successProp.Value, [bool])
  } catch {
    return [pscustomobject]@{
      status = 'INVALID'
      detail = ("invalid success value: {0}" -f [string]$successProp.Value)
    }
  }

  return [pscustomobject]@{
    status = $(if ($successValue) { 'PASS' } else { 'FAIL' })
    detail = ("{0}={1}" -f $SuccessProperty, $successValue.ToString().ToLowerInvariant())
  }
}
