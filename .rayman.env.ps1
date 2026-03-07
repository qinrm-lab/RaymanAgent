
# Rayman dependency auto-heal defaults (managed by setup)
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AUTO_INSTALL_TEST_DEPS)) {
    $env:RAYMAN_AUTO_INSTALL_TEST_DEPS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_REQUIRE_TEST_DEPS)) {
    $env:RAYMAN_REQUIRE_TEST_DEPS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL)) {
    $env:RAYMAN_SELF_HEAL_AUTO_DEP_INSTALL = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_PLAYWRIGHT_REQUIRE)) {
    $env:RAYMAN_PLAYWRIGHT_REQUIRE = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_PLAYWRIGHT_AUTO_INSTALL)) {
    $env:RAYMAN_PLAYWRIGHT_AUTO_INSTALL = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_GIT_SAFECRLF_SUPPRESS)) {
    $env:RAYMAN_GIT_SAFECRLF_SUPPRESS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AUTO_REPAIR_NESTED_RAYMAN)) {
    $env:RAYMAN_AUTO_REPAIR_NESTED_RAYMAN = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_ENABLED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_COPY_BROWSERS = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_REFRESH_HOURS = '24'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE)) {
    $env:RAYMAN_SANDBOX_OFFLINE_CACHE_FORCE = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_DOTNET_WINDOWS_PREFERRED)) {
    $env:RAYMAN_DOTNET_WINDOWS_PREFERRED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_DOTNET_WINDOWS_STRICT)) {
    $env:RAYMAN_DOTNET_WINDOWS_STRICT = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS)) {
    $env:RAYMAN_DOTNET_WINDOWS_TIMEOUT_SECONDS = '1800'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_DEFAULT_BACKEND)) {
    $env:RAYMAN_AGENT_DEFAULT_BACKEND = 'local'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_FALLBACK_ORDER)) {
    $env:RAYMAN_AGENT_FALLBACK_ORDER = 'codex,local'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_CLOUD_ENABLED)) {
    $env:RAYMAN_AGENT_CLOUD_ENABLED = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_POLICY_BYPASS)) {
    $env:RAYMAN_AGENT_POLICY_BYPASS = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_AGENT_CLOUD_WHITELIST)) {
    $env:RAYMAN_AGENT_CLOUD_WHITELIST = ''
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_FIRST_PASS_WINDOW)) {
    $env:RAYMAN_FIRST_PASS_WINDOW = '20'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS)) {
    $env:RAYMAN_REVIEW_LOOP_MAX_ROUNDS = '2'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_HEARTBEAT_SECONDS)) {
    $env:RAYMAN_HEARTBEAT_SECONDS = '60'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_HEARTBEAT_VERBOSE)) {
    $env:RAYMAN_HEARTBEAT_VERBOSE = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED)) {
    $env:RAYMAN_HEARTBEAT_SMART_SILENCE_ENABLED = '1'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS)) {
    $env:RAYMAN_HEARTBEAT_SILENT_WINDOW_SECONDS = '600'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_RAG_HEARTBEAT_SECONDS)) {
    $env:RAYMAN_RAG_HEARTBEAT_SECONDS = '90'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_SANDBOX_HEARTBEAT_SECONDS)) {
    $env:RAYMAN_SANDBOX_HEARTBEAT_SECONDS = '90'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_MCP_HEARTBEAT_SECONDS)) {
    $env:RAYMAN_MCP_HEARTBEAT_SECONDS = '90'
}


# Rayman dependency auto-heal defaults (managed by setup)
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_USE_SANDBOX)) {
    $env:RAYMAN_USE_SANDBOX = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_PRESERVE_RAG_NAMESPACE)) {
    $env:RAYMAN_PRESERVE_RAG_NAMESPACE = '0'
}
if ([string]::IsNullOrWhiteSpace([string]$env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE)) {
    $env:RAYMAN_PLAYWRIGHT_SETUP_SCOPE = 'wsl'
}

