BeforeAll {
  $script:WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
  . (Join-Path $script:WorkspaceRoot '.Rayman\scripts\worker\manage_workers.ps1') -NoMain
}

Describe 'worker manage helpers' {
  It 'preserves spaced paths and quoted args for worker exec commands' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rayman worker manage ' + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Force -Path $root | Out-Null
      $scriptPath = Join-Path $root 'echo args.ps1'
      Set-Content -LiteralPath $scriptPath -Encoding UTF8 -Value @'
param([string]$WorkspaceRoot, [string]$Label)
Write-Output $WorkspaceRoot
Write-Output $Label
'@

      $commandText = Format-RaymanWorkerCommandText -CommandParts @($scriptPath, '-WorkspaceRoot', $root, '-Label', "O'Brien")
      $psHost = Resolve-RaymanPowerShellHost
      $output = @(& $psHost -NoProfile -ExecutionPolicy Bypass -Command $commandText 2>&1 | ForEach-Object { [string]$_ })

      $LASTEXITCODE | Should -Be 0
      $output | Should -Contain $root
      $output | Should -Contain "O'Brien"
    } finally {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses an encoded command for scheduled task registration' {
    $scriptPath = 'C:\Users\Test User\My Repo\.Rayman\scripts\worker\worker_host.ps1'
    $workspaceRoot = 'C:\Users\Test User\My Repo'

    $argumentText = Get-RaymanWorkerScheduledTaskArguments -WorkerHostScript $scriptPath -WorkspaceRoot $workspaceRoot
    $encoded = $argumentText -replace '^-NoProfile -ExecutionPolicy Bypass -EncodedCommand ', ''
    $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))

    $argumentText | Should -Match '^-NoProfile -ExecutionPolicy Bypass -EncodedCommand '
    $decoded | Should -Be "& 'C:\Users\Test User\My Repo\.Rayman\scripts\worker\worker_host.ps1' -WorkspaceRoot 'C:\Users\Test User\My Repo'"
  }
}
