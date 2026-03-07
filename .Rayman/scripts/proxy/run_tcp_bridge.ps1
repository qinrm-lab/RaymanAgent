param(
  [string]$ListenAddress = '0.0.0.0',
  [Parameter(Mandatory=$true)][int]$ListenPort,
  [Parameter(Mandatory=$true)][string]$TargetHost,
  [Parameter(Mandatory=$true)][int]$TargetPort,
  [string]$PidFile = '',
  [string]$LogFile = '',
  [string]$StateFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-BridgeLog([string]$Message) {
  $line = ("[{0}] [proxy-bridge] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message)
  Write-Host $line
  if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
  try {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  } catch {}
}

if ($ListenPort -lt 1 -or $ListenPort -gt 65535) { throw "invalid ListenPort: $ListenPort" }
if ($TargetPort -lt 1 -or $TargetPort -gt 65535) { throw "invalid TargetPort: $TargetPort" }

if (-not [string]::IsNullOrWhiteSpace($PidFile)) {
  try {
    $dir = Split-Path -Parent $PidFile
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Set-Content -LiteralPath $PidFile -Value $PID -NoNewline -Encoding ASCII
  } catch {
    Write-BridgeLog ("write pid file failed: {0}" -f $_.Exception.Message)
  }
}

if (-not [string]::IsNullOrWhiteSpace($StateFile)) {
  try {
    $stateDir = Split-Path -Parent $StateFile
    if ($stateDir -and -not (Test-Path -LiteralPath $stateDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    }
    $payload = [ordered]@{
      pid         = $PID
      listen      = ('{0}:{1}' -f $ListenAddress, $ListenPort)
      target      = ('{0}:{1}' -f $TargetHost, $TargetPort)
      startedAt   = (Get-Date).ToString('o')
      script      = $MyInvocation.MyCommand.Path
    }
    ($payload | ConvertTo-Json -Depth 5) | Out-File -FilePath $StateFile -Encoding utf8
  } catch {
    Write-BridgeLog ("write state file failed: {0}" -f $_.Exception.Message)
  }
}

$typeName = 'RaymanTcpBridgeHost'
if (-not ($typeName -as [type])) {
  $oldTemp = $env:TEMP
  $oldTmp = $env:TMP
  $compileTempRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\runtime')).Path 'tmp\proxy-bridge'
  try {
    if (-not (Test-Path -LiteralPath $compileTempRoot -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $compileTempRoot | Out-Null
    }
    $env:TEMP = $compileTempRoot
    $env:TMP = $compileTempRoot
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;

public static class RaymanTcpBridgeHost
{
    private static void Log(string path, string message)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try
        {
            string line = string.Format("[{0}] [proxy-bridge] {1}{2}",
              DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
              message,
              Environment.NewLine);
            File.AppendAllText(path, line);
        }
        catch { }
    }

    private static async Task PumpAsync(NetworkStream source, NetworkStream destination)
    {
        byte[] buffer = new byte[81920];
        while (true)
        {
            int n = await source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
            if (n <= 0) break;
            await destination.WriteAsync(buffer, 0, n).ConfigureAwait(false);
            await destination.FlushAsync().ConfigureAwait(false);
        }
    }

    private static async Task HandleClientAsync(TcpClient inbound, string targetHost, int targetPort, string logFile)
    {
        using (inbound)
        {
            try
            {
                using (TcpClient outbound = new TcpClient())
                {
                    Log(logFile, "connecting upstream to " + targetHost + ":" + targetPort.ToString());
                    await outbound.ConnectAsync(targetHost, targetPort).ConfigureAwait(false);
                    using (NetworkStream inStream = inbound.GetStream())
                    using (NetworkStream outStream = outbound.GetStream())
                    {
                        Task t1 = PumpAsync(inStream, outStream);
                        Task t2 = PumpAsync(outStream, inStream);
                        await Task.WhenAny(t1, t2).ConfigureAwait(false);
                    }
                }
            }
            catch (Exception ex)
            {
                Log(logFile, "connection relay failed: " + ex.Message);
            }
        }
    }

    public static void Run(string listenAddress, int listenPort, string targetHost, int targetPort, string logFile)
    {
        IPAddress bindAddress;
        if (!IPAddress.TryParse(listenAddress, out bindAddress))
        {
            bindAddress = IPAddress.Any;
        }

        TcpListener listener = new TcpListener(bindAddress, listenPort);
        listener.Start(512);
        Log(logFile, string.Format("bridge listening {0}:{1} -> {2}:{3}",
            bindAddress, listenPort, targetHost, targetPort));

        while (true)
        {
            TcpClient client = listener.AcceptTcpClient();
            try
            {
                Log(logFile, "accepted client " + client.Client.RemoteEndPoint.ToString());
            }
            catch { }
            Task ignored = HandleClientAsync(client, targetHost, targetPort, logFile);
        }
    }
}
"@ -Language CSharp -ErrorAction Stop
  } finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
  }
}

Write-BridgeLog ("start bridge {0}:{1} -> {2}:{3}" -f $ListenAddress, $ListenPort, $TargetHost, $TargetPort)
try {
  [RaymanTcpBridgeHost]::Run($ListenAddress, $ListenPort, $TargetHost, $TargetPort, $LogFile)
} catch {
  Write-BridgeLog ("bridge fatal: {0}" -f $_.Exception.Message)
  throw
}
