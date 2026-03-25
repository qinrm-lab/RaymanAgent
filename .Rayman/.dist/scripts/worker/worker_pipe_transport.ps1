param(
  [string]$WorkspaceRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$PipeArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker_common.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$manifest = Get-RaymanWorkerDebugManifest -WorkspaceRoot $WorkspaceRoot
if ($null -eq $manifest) {
  throw 'worker debug manifest missing; run `rayman.ps1 worker debug --mode launch` first.'
}
if ($manifest.PSObject.Properties['debugger_ready'] -and -not [bool]$manifest.debugger_ready) {
  $message = if ($manifest.PSObject.Properties['debugger_error'] -and -not [string]::IsNullOrWhiteSpace([string]$manifest.debugger_error)) {
    [string]$manifest.debugger_error
  } else {
    'worker debugger is not ready'
  }
  throw ("{0}. Remediation: run `rayman.ps1 worker status`, verify debugger_ready=true, or preseed RAYMAN_WORKER_VSDBG_PATH on the worker." -f $message)
}

$context = Get-RaymanWorkerActiveExecutionContext -WorkspaceRoot $WorkspaceRoot
if ($null -eq $context) {
  throw 'no active worker selected'
}

$worker = $context.worker
$debuggerPath = if ($PipeArguments.Count -gt 0) { [string]$PipeArguments[0] } elseif ($manifest.PSObject.Properties['debugger_path']) { [string]$manifest.debugger_path } else { '' }
if ([string]::IsNullOrWhiteSpace([string]$debuggerPath)) {
  throw 'worker debug manifest is missing debugger_path; run `rayman.ps1 worker debug --mode launch|attach` again after ensuring vsdbg is installed on the worker.'
}
$debuggerArgs = if ($PipeArguments.Count -gt 1) { @($PipeArguments | Select-Object -Skip 1) } else { @() }
$workingDirectory = if ($manifest.PSObject.Properties['cwd']) { [string]$manifest.cwd } else { [string]$manifest.execution_root }

$tunnel = Invoke-RaymanWorkerControlRequest -Worker $worker -Method POST -Path '/debug/tunnel' -Body ([pscustomobject]@{
    debugger_path = $debuggerPath
    debugger_arguments = @($debuggerArgs)
    working_directory = $workingDirectory
  }) -TimeoutSeconds 30 -WorkspaceRoot $WorkspaceRoot

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect([string]$tunnel.address, [int]$tunnel.port)
try {
  $network = $client.GetStream()
  $stdin = [Console]::OpenStandardInput()
  $stdout = [Console]::OpenStandardOutput()

  $writeTask = $stdin.CopyToAsync($network)
  $readTask = $network.CopyToAsync($stdout)

  $readTask.Wait() | Out-Null
  try {
    $network.Flush()
  } catch {}
  try {
    $writeTask.Wait(1000) | Out-Null
  } catch {}
} finally {
  try { $client.Close() } catch {}
}
