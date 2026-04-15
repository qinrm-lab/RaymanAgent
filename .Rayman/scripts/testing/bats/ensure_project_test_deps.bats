#!/usr/bin/env bats

setup_file() {
  export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../../.." && pwd)"
  export BATS_TMP_MNT_PARENT="${REPO_ROOT}/.Rayman/runtime/bats_maui"
  mkdir -p "${BATS_TMP_MNT_PARENT}"
}

setup() {
  export RAYMAN_BATS_CREATED_PATHS=""
}

track_cleanup_path() {
  local path="${1:-}"
  if [[ -z "${path}" ]]; then
    return 0
  fi
  if [[ -n "${RAYMAN_BATS_CREATED_PATHS}" ]]; then
    RAYMAN_BATS_CREATED_PATHS+=$'\n'
  fi
  RAYMAN_BATS_CREATED_PATHS+="${path}"
}

write_maui_fixture() {
  local root="$1"
  mkdir -p "${root}/DeleteDir" "${root}/.Rayman/scripts/utils"
  cat > "${root}/DeleteDir/DeleteDir.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk.Razor">
  <PropertyGroup>
    <TargetFrameworks>net10.0-android;net10.0-ios;net10.0-maccatalyst</TargetFrameworks>
    <TargetFrameworks Condition="$([MSBuild]::IsOSPlatform('windows'))">$(TargetFrameworks);net10.0-windows10.0.19041.0</TargetFrameworks>
    <UseMaui>true</UseMaui>
    <SingleProject>true</SingleProject>
  </PropertyGroup>
</Project>
XML
  cat > "${root}/Tools.slnx" <<'XML'
<Solution>
  <Project Path="DeleteDir/DeleteDir.csproj" />
</Solution>
XML
  touch "${root}/.Rayman/scripts/utils/ensure_project_test_deps.ps1"
}

write_stub_bin() {
  local root="$1"
  local mode="${2:-bridge}"
  mkdir -p "${root}/bin"

  cat > "${root}/bin/dotnet" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log_path="${DOTNET_STUB_LOG:?}"
printf '%s\n' "$*" >> "${log_path}"
case "${1:-}" in
  --version)
    echo "10.0.103"
    ;;
  --info)
    echo ".NET SDK"
    ;;
  --list-sdks)
    echo "10.0.103 [/tmp/dotnet/sdk]"
    ;;
  workload)
    if [[ "${2:-}" == "restore" ]]; then
      echo "workload-restore:${3:-}"
      exit 0
    fi
    ;;
esac
exit 0
SH
  chmod +x "${root}/bin/dotnet"

  if [[ "${mode}" == "bridge" ]]; then
    cat > "${root}/bin/powershell.exe" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log_path="${POWERSHELL_STUB_LOG:?}"
printf '%s\n' "$*" >> "${log_path}"
echo "bridge-ok"
exit 0
SH
    chmod +x "${root}/bin/powershell.exe"

    cat > "${root}/bin/wslpath" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-w" ]]; then
  raw="${2:-}"
  if [[ "${raw}" =~ ^/mnt/([A-Za-z])/(.*)$ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]//\//\\}"
    printf '%s:\\%s\r\n' "${drive^^}" "${rest}"
    exit 0
  fi
fi
printf '%s\r\n' "${2:-}"
SH
    chmod +x "${root}/bin/wslpath"
  fi
}

make_mnt_workspace() {
  local root
  root="$(mktemp -d "${BATS_TMP_MNT_PARENT}/ensure_deps_XXXXXX")"
  write_maui_fixture "${root}"
  echo "${root}"
}

make_tmp_workspace() {
  local root
  root="$(mktemp -d)"
  write_maui_fixture "${root}"
  echo "${root}"
}

teardown() {
  if [[ -n "${RAYMAN_BATS_CREATED_PATHS:-}" ]]; then
    while IFS= read -r path; do
      if [[ -n "${path}" && -e "${path}" ]]; then
        rm -rf "${path}"
      fi
    done <<< "${RAYMAN_BATS_CREATED_PATHS}"
  fi
  if [[ -n "${BATS_TEST_TMPDIR:-}" && -d "${BATS_TEST_TMPDIR}" ]]; then
    rm -rf "${BATS_TEST_TMPDIR}"
  fi
}

teardown_file() {
  if [[ -n "${BATS_TMP_MNT_PARENT:-}" && -d "${BATS_TMP_MNT_PARENT}" ]]; then
    rmdir "${BATS_TMP_MNT_PARENT}" 2>/dev/null || true
  fi
}

@test "MAUI dependency ensure prefers Windows bridge for workload restore on WSL" {
  local fixture stub_root
  fixture="$(make_mnt_workspace)"
  track_cleanup_path "${fixture}"
  stub_root="$(mktemp -d "${BATS_TMP_MNT_PARENT}/stub_bridge_XXXXXX")"
  track_cleanup_path "${stub_root}"
  write_stub_bin "${stub_root}" bridge

  export DOTNET_STUB_LOG="${stub_root}/dotnet.log"
  export POWERSHELL_STUB_LOG="${stub_root}/powershell.log"
  touch "${DOTNET_STUB_LOG}" "${POWERSHELL_STUB_LOG}"

  run env \
    PATH="${stub_root}/bin:${PATH}" \
    WSL_INTEROP=1 \
    RAYMAN_DOTNET_WINDOWS_PREFERRED=1 \
    bash "${REPO_ROOT}/.Rayman/scripts/utils/ensure_project_test_deps.sh" --workspace-root "${fixture}"

  [ "${status}" -eq 0 ]
  grep -q "MAUI project detected; preferring Windows host dependency flow" <<< "${output}"
  grep -q "ensure_project_test_deps.ps1" "${POWERSHELL_STUB_LOG}"
}

@test "MAUI dependency ensure falls back to local workload restore when bridge is unavailable" {
  local fixture stub_root
  fixture="$(make_tmp_workspace)"
  track_cleanup_path "${fixture}"
  stub_root="$(mktemp -d)"
  track_cleanup_path "${stub_root}"
  write_stub_bin "${stub_root}" local

  export DOTNET_STUB_LOG="${stub_root}/dotnet.log"
  touch "${DOTNET_STUB_LOG}"

  run env \
    PATH="${stub_root}/bin:${PATH}" \
    WSL_INTEROP=1 \
    RAYMAN_DOTNET_WINDOWS_PREFERRED=1 \
    bash "${REPO_ROOT}/.Rayman/scripts/utils/ensure_project_test_deps.sh" --workspace-root "${fixture}"

  [ "${status}" -eq 0 ]
  grep -q "workload restore" "${DOTNET_STUB_LOG}"
}
