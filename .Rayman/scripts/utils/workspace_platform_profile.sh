#!/usr/bin/env bash
set -euo pipefail

rayman_platform_workspace_root="${1:-$(pwd)}"
rayman_platform_workspace_root="$(cd "${rayman_platform_workspace_root}" && pwd)"

rayman_platform_needs_dotnet=0
rayman_platform_has_windows_targeting=0
rayman_platform_has_windows_desktop_ui=0
rayman_platform_requires_windows_host=0
rayman_platform_allows_windows_dotnet_bridge=0
rayman_platform_auto_enable_windows=0
rayman_platform_is_windows_only_desktop_project=0
declare -a rayman_platform_dotnet_project_paths=()
declare -a rayman_platform_target_frameworks=()
declare -a rayman_platform_windows_project_paths=()
declare -a rayman_platform_maui_projects=()

rayman_platform_reset() {
  rayman_platform_needs_dotnet=0
  rayman_platform_has_windows_targeting=0
  rayman_platform_has_windows_desktop_ui=0
  rayman_platform_requires_windows_host=0
  rayman_platform_allows_windows_dotnet_bridge=0
  rayman_platform_auto_enable_windows=0
  rayman_platform_is_windows_only_desktop_project=0
  rayman_platform_dotnet_project_paths=()
  rayman_platform_target_frameworks=()
  rayman_platform_windows_project_paths=()
  rayman_platform_maui_projects=()
}

rayman_platform_has_item() {
  local needle="${1:-}"
  shift || true
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

rayman_platform_normalize_xml() {
  tr '\r\n' '  ' < "$1"
}

rayman_platform_extract_target_frameworks() {
  local path="$1"
  local raw match value part
  raw="$(rayman_platform_normalize_xml "${path}")"
  while IFS= read -r match; do
    value="$(printf '%s' "${match}" | sed -E 's#<TargetFrameworks?[^>]*>[[:space:]]*([^<]*)[[:space:]]*</TargetFrameworks?>#\1#I')"
    IFS=';' read -ra tf_parts <<< "${value}"
    for part in "${tf_parts[@]}"; do
      part="$(echo "${part}" | xargs)"
      [[ -z "${part}" ]] && continue
      [[ "${part}" == *'$('* ]] && continue
      echo "${part}"
    done
  done < <(printf '%s' "${raw}" | grep -oEi '<TargetFrameworks?[^>]*>[^<]*</TargetFrameworks?>' || true)
}

rayman_platform_collect() {
  local root="${1:-${rayman_platform_workspace_root}}"
  local path name raw lower use_maui use_wpf use_winforms use_winui use_windowsappsdk
  local has_windows_target has_non_windows_target has_windows_desktop_ui requires_windows_host windows_only framework

  root="$(cd "${root}" && pwd)"
  rayman_platform_reset
  rayman_platform_workspace_root="${root}"

  while IFS= read -r -d '' path; do
    name="$(basename "${path}")"
    case "${name}" in
      *.sln|*.slnx|*.csproj|*.fsproj|*.vbproj)
        rayman_platform_needs_dotnet=1
        if ! rayman_platform_has_item "${path}" "${rayman_platform_dotnet_project_paths[@]:-}"; then
          rayman_platform_dotnet_project_paths+=("${path}")
        fi

        raw=""
        if [[ "${name}" == *.csproj || "${name}" == *.fsproj || "${name}" == *.vbproj ]]; then
          raw="$(cat "${path}")"
        fi
        lower="${raw,,}"
        use_maui=0
        use_wpf=0
        use_winforms=0
        use_winui=0
        use_windowsappsdk=0
        has_windows_target=0
        has_non_windows_target=0

        if [[ "${lower}" == *"<usemaui>true</usemaui>"* ]]; then use_maui=1; fi
        if [[ "${lower}" == *"<usewpf>true</usewpf>"* ]]; then use_wpf=1; fi
        if [[ "${lower}" == *"<usewindowsforms>true</usewindowsforms>"* ]]; then use_winforms=1; fi
        if [[ "${lower}" == *"<usewinui>true</usewinui>"* || "${lower}" == *"microsoft.ui.xaml"* || "${lower}" == *"winuiex"* ]]; then use_winui=1; fi
        if [[ "${lower}" == *"microsoft.windowsappsdk"* || "${lower}" == *"windowsappsdkselfcontained"* || "${lower}" == *"windowsappsdkdeploymentmanager"* || "${lower}" == *"package.appxmanifest"* ]]; then
          use_windowsappsdk=1
        fi

        while IFS= read -r framework; do
          [[ -z "${framework}" ]] && continue
          if ! rayman_platform_has_item "${framework}" "${rayman_platform_target_frameworks[@]:-}"; then
            rayman_platform_target_frameworks+=("${framework}")
          fi
          if [[ "${framework}" == *"-windows"* ]]; then
            has_windows_target=1
          else
            has_non_windows_target=1
          fi
        done < <(rayman_platform_extract_target_frameworks "${path}")

        has_windows_desktop_ui=0
        requires_windows_host=0
        windows_only=0

        if [[ "${use_maui}" == "1" || "${use_wpf}" == "1" || "${use_winforms}" == "1" || "${use_winui}" == "1" || "${use_windowsappsdk}" == "1" ]]; then
          has_windows_desktop_ui=1
        fi
        if [[ "${has_windows_desktop_ui}" == "1" || "${has_windows_target}" == "1" ]]; then
          requires_windows_host=1
        fi
        if [[ "${use_wpf}" == "1" || "${use_winforms}" == "1" || "${use_winui}" == "1" || "${use_windowsappsdk}" == "1" ]]; then
          windows_only=1
        elif [[ "${has_windows_target}" == "1" && "${has_non_windows_target}" == "0" ]]; then
          windows_only=1
        fi

        if [[ "${requires_windows_host}" == "1" ]]; then
          rayman_platform_requires_windows_host=1
          rayman_platform_allows_windows_dotnet_bridge=1
          rayman_platform_auto_enable_windows=1
          if ! rayman_platform_has_item "${path}" "${rayman_platform_windows_project_paths[@]:-}"; then
            rayman_platform_windows_project_paths+=("${path}")
          fi
        fi
        if [[ "${has_windows_target}" == "1" || "${has_windows_desktop_ui}" == "1" ]]; then
          rayman_platform_has_windows_targeting=1
        fi
        if [[ "${has_windows_desktop_ui}" == "1" ]]; then
          rayman_platform_has_windows_desktop_ui=1
        fi
        if [[ "${windows_only}" == "1" ]]; then
          rayman_platform_is_windows_only_desktop_project=1
        fi
        if [[ "${use_maui}" == "1" ]]; then
          if ! rayman_platform_has_item "${path}" "${rayman_platform_maui_projects[@]:-}"; then
            rayman_platform_maui_projects+=("${path}")
          fi
        fi
        ;;
    esac
  done < <(find "${root}" -type f \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' -o -name '*.fsproj' -o -name '*.vbproj' \) \
    -not -path "${root}/.git/*" -not -path "${root}/.Rayman/*" -not -path "${root}/.venv/*" -not -path "${root}/node_modules/*" -not -path "${root}/bin/*" -not -path "${root}/obj/*" -print0)
}
