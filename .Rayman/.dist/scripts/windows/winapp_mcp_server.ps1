param(
  [string]$WorkspaceRoot = $(Resolve-Path "$PSScriptRoot\..\..\.." | Select-Object -ExpandProperty Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'winapp_core.ps1')

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$paths = Get-WinAppRuntimePaths -WorkspaceRoot $WorkspaceRoot
Ensure-Dir -Path $paths.runtime_dir
Ensure-Dir -Path $paths.logs_dir
$serverLog = Join-Path $paths.logs_dir 'winapp.mcp.log'

$script:Reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)), $false)
$script:WriterStream = [Console]::OpenStandardOutput()

function Write-McpPayload {
  param(
    [object]$Payload
  )

  $json = $Payload | ConvertTo-Json -Depth 20 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $header = [System.Text.Encoding]::ASCII.GetBytes(("Content-Length: {0}`r`n`r`n" -f $bytes.Length))
  $script:WriterStream.Write($header, 0, $header.Length)
  $script:WriterStream.Write($bytes, 0, $bytes.Length)
  $script:WriterStream.Flush()
}

function Read-McpPayload {
  $contentLength = 0
  while ($true) {
    $line = $script:Reader.ReadLine()
    if ($null -eq $line) { return $null }
    if ([string]::IsNullOrEmpty($line)) { break }
    if ($line -match '^Content-Length:\s*(\d+)\s*$') {
      $contentLength = [int]$matches[1]
    }
  }

  if ($contentLength -le 0) { return $null }
  $buffer = New-Object char[] $contentLength
  $read = 0
  while ($read -lt $contentLength) {
    $chunk = $script:Reader.Read($buffer, $read, $contentLength - $read)
    if ($chunk -le 0) { return $null }
    $read += $chunk
  }

  $json = -join $buffer
  return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Write-McpResponse {
  param(
    [object]$Id,
    [object]$Result
  )

  Write-McpPayload -Payload ([ordered]@{
      jsonrpc = '2.0'
      id = $Id
      result = $Result
    })
}

function Write-McpError {
  param(
    [object]$Id,
    [int]$Code,
    [string]$Message
  )

  Write-McpPayload -Payload ([ordered]@{
      jsonrpc = '2.0'
      id = $Id
      error = [ordered]@{
        code = $Code
        message = $Message
      }
    })
}

function New-McpToolResult {
  param(
    [object]$Payload,
    [bool]$IsError = $false
  )

  $text = $Payload | ConvertTo-Json -Depth 20
  $result = [ordered]@{
    content = @(
      [ordered]@{
        type = 'text'
        text = $text
      }
    )
    structuredContent = $Payload
  }
  if ($IsError) {
    $result['isError'] = $true
  }
  return $result
}

function Get-McpToolDefinitions {
  return @(
    [ordered]@{
      name = 'list_windows'
      description = 'List top-level Windows desktop windows available to Rayman UI Automation.'
      inputSchema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
          window_title_regex = [ordered]@{ type = 'string' }
          process_name = [ordered]@{ type = 'string' }
        }
      }
    },
    [ordered]@{
      name = 'get_control_tree'
      description = 'Export a UI Automation control tree for a top-level window.'
      inputSchema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
          window_title_regex = [ordered]@{ type = 'string' }
          process_name = [ordered]@{ type = 'string' }
          max_depth = [ordered]@{ type = 'integer' }
        }
      }
    },
    [ordered]@{
      name = 'run_winapp_flow'
      description = 'Run a Rayman Windows desktop automation flow file.'
      inputSchema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
          flow_file = [ordered]@{ type = 'string' }
          default_timeout_ms = [ordered]@{ type = 'integer' }
          require = [ordered]@{ type = 'boolean' }
        }
        required = @('flow_file')
      }
    },
    [ordered]@{
      name = 'capture_window'
      description = 'Capture a screenshot of a matched top-level window.'
      inputSchema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
          window_title_regex = [ordered]@{ type = 'string' }
          process_name = [ordered]@{ type = 'string' }
          output_file = [ordered]@{ type = 'string' }
        }
      }
    }
  )
}

function Invoke-McpToolCall {
  param(
    [string]$Name,
    [object]$Arguments
  )

  $state = Get-WinAppReadinessState -WorkspaceRoot $WorkspaceRoot
  Write-WinAppReadinessReport -WorkspaceRoot $WorkspaceRoot -State $state | Out-Null

  switch ($Name) {
    'list_windows' {
      if (-not [bool]$state.ready) {
        return (New-McpToolResult -Payload ([ordered]@{
              ready = $false
              reason = [string]$state.reason
              detail = [string]$state.detail
              windows = @()
            }))
      }

      $regex = [string](Get-PropValue -Object $Arguments -Name 'window_title_regex' -Default '.*')
      $processName = [string](Get-PropValue -Object $Arguments -Name 'process_name' -Default '')
      $windows = @(Get-WinAppTopLevelWindowElements -WindowTitleRegex $regex -ProcessName $processName | ForEach-Object { ConvertTo-WinAppElementInfo -Element $_ })
      return (New-McpToolResult -Payload ([ordered]@{
            ready = $true
            windows = $windows
          }))
    }
    'get_control_tree' {
      if (-not [bool]$state.ready) {
        return (New-McpToolResult -Payload ([ordered]@{
              ready = $false
              reason = [string]$state.reason
              detail = [string]$state.detail
            }))
      }

      $regex = [string](Get-PropValue -Object $Arguments -Name 'window_title_regex' -Default '.*')
      $processName = [string](Get-PropValue -Object $Arguments -Name 'process_name' -Default '')
      $maxDepth = [int](Get-PropValue -Object $Arguments -Name 'max_depth' -Default 6)
      $window = Wait-WinAppWindow -WindowTitleRegex $regex -ProcessName $processName -TimeoutSeconds 10
      if ($null -eq $window) {
        return (New-McpToolResult -Payload ([ordered]@{
              ready = $true
              found = $false
              reason = 'window_not_found'
            }) -IsError:$true)
      }

      $tree = Get-WinAppWindowControlTree -Window $window -MaxDepth $maxDepth
      return (New-McpToolResult -Payload ([ordered]@{
            ready = $true
            found = $true
            window = ConvertTo-WinAppElementInfo -Element $window
            tree = $tree.tree
          }))
    }
    'run_winapp_flow' {
      $flowFile = [string](Get-PropValue -Object $Arguments -Name 'flow_file' -Default '')
      if ([string]::IsNullOrWhiteSpace($flowFile)) {
        return (New-McpToolResult -Payload ([ordered]@{
              ready = [bool]$state.ready
              reason = 'flow_file_missing'
            }) -IsError:$true)
      }

      $flowPath = if ([System.IO.Path]::IsPathRooted($flowFile)) { $flowFile } else { Join-Path $WorkspaceRoot $flowFile }
      $defaultTimeoutMs = [int](Get-PropValue -Object $Arguments -Name 'default_timeout_ms' -Default 0)
      $require = [bool](Get-PropValue -Object $Arguments -Name 'require' -Default $false)
      $result = & (Join-Path $PSScriptRoot 'run_winapp_flow.ps1') -WorkspaceRoot $WorkspaceRoot -FlowFile $flowPath -DefaultTimeoutMs $defaultTimeoutMs -Require:$require -Json | ConvertFrom-Json -ErrorAction Stop
      return (New-McpToolResult -Payload $result -IsError:(-not [bool]$result.success))
    }
    'capture_window' {
      if (-not [bool]$state.ready) {
        return (New-McpToolResult -Payload ([ordered]@{
              ready = $false
              reason = [string]$state.reason
              detail = [string]$state.detail
            }))
      }

      $regex = [string](Get-PropValue -Object $Arguments -Name 'window_title_regex' -Default '.*')
      $processName = [string](Get-PropValue -Object $Arguments -Name 'process_name' -Default '')
      $outputFile = [string](Get-PropValue -Object $Arguments -Name 'output_file' -Default (Join-Path $paths.screenshots_dir ('mcp-{0}.png' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))))
      $window = Wait-WinAppWindow -WindowTitleRegex $regex -ProcessName $processName -TimeoutSeconds 10
      if ($null -eq $window) {
        return (New-McpToolResult -Payload ([ordered]@{
              ready = $true
              found = $false
              reason = 'window_not_found'
            }) -IsError:$true)
      }

      $resolvedOutput = if ([System.IO.Path]::IsPathRooted($outputFile)) { $outputFile } else { Join-Path $WorkspaceRoot $outputFile }
      $saved = Capture-WinAppElementToFile -Element $window -Path $resolvedOutput
      return (New-McpToolResult -Payload ([ordered]@{
            ready = $true
            found = $true
            screenshot_path = $saved
            window = ConvertTo-WinAppElementInfo -Element $window
          }))
    }
    default {
      return (New-McpToolResult -Payload ([ordered]@{
            reason = 'unknown_tool'
            tool = $Name
          }) -IsError:$true)
    }
  }
}

Write-WinAppLogLine -Path $serverLog -Level 'info' -Message ('server_start workspace={0}' -f $WorkspaceRoot)

while ($true) {
  $message = $null
  try {
    $message = Read-McpPayload
  } catch {
    Write-WinAppLogLine -Path $serverLog -Level 'error' -Message $_.Exception.ToString()
    break
  }

  if ($null -eq $message) { break }

  $id = Get-PropValue -Object $message -Name 'id' -Default $null
  $method = [string](Get-PropValue -Object $message -Name 'method' -Default '')
  $params = Get-PropValue -Object $message -Name 'params' -Default $null

  try {
    switch ($method) {
      'initialize' {
        $protocolVersion = [string](Get-PropValue -Object $params -Name 'protocolVersion' -Default '2024-11-05')
        Write-McpResponse -Id $id -Result ([ordered]@{
            protocolVersion = $protocolVersion
            capabilities = [ordered]@{
              tools = [ordered]@{
                listChanged = $false
              }
            }
            serverInfo = [ordered]@{
              name = 'raymanWinApp'
              version = '1.0.0'
            }
          })
      }
      'notifications/initialized' {
        continue
      }
      'ping' {
        Write-McpResponse -Id $id -Result ([ordered]@{})
      }
      'tools/list' {
        Write-McpResponse -Id $id -Result ([ordered]@{
            tools = @(Get-McpToolDefinitions)
          })
      }
      'tools/call' {
        $toolName = [string](Get-PropValue -Object $params -Name 'name' -Default '')
        $toolArgs = Get-PropValue -Object $params -Name 'arguments' -Default $null
        $toolResult = Invoke-McpToolCall -Name $toolName -Arguments $toolArgs
        Write-McpResponse -Id $id -Result $toolResult
      }
      default {
        if ($null -ne $id) {
          Write-McpError -Id $id -Code -32601 -Message ('Method not found: {0}' -f $method)
        }
      }
    }
  } catch {
    Write-WinAppLogLine -Path $serverLog -Level 'error' -Message $_.Exception.ToString()
    if ($null -ne $id) {
      Write-McpError -Id $id -Code -32603 -Message $_.Exception.Message
    }
  }
}

Write-WinAppLogLine -Path $serverLog -Level 'info' -Message 'server_stop'
