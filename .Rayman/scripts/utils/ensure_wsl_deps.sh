#!/usr/bin/env bash
set -euo pipefail

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_pkg() {
  dpkg -s "$1" >/dev/null 2>&1 && return 1
  return 0
}

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "[rayman] warning: expected Ubuntu, found ${ID:-unknown}; continuing anyway"
  fi
fi

echo "[rayman] requesting sudo..."
sudo -v

base_pkgs=(git curl ca-certificates wget apt-transport-https)
extra_pkgs=(libnotify-bin espeak-ng speech-dispatcher)
to_install=()

for pkg in "${base_pkgs[@]}"; do
  if need_pkg "$pkg"; then to_install+=("$pkg"); fi
done
for pkg in "${extra_pkgs[@]}"; do
  if need_pkg "$pkg"; then to_install+=("$pkg"); fi
done

if [[ ${#to_install[@]} -gt 0 ]]; then
  echo "[rayman] installing apt packages: ${to_install[*]}"
  sudo apt-get update
  sudo apt-get install -y "${to_install[@]}"
else
  echo "[rayman] apt packages already satisfied"
fi

if ! have_cmd pwsh; then
  echo "[rayman] pwsh not found; installing PowerShell via Microsoft repo..."
  source /etc/os-release
  version_id="${VERSION_ID:-24.04}"
  ms_deb="/tmp/packages-microsoft-prod.deb"
  wget -q "https://packages.microsoft.com/config/ubuntu/${version_id}/packages-microsoft-prod.deb" -O "$ms_deb" || \
    wget -q "https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb" -O "$ms_deb"
  sudo dpkg -i "$ms_deb"
  sudo apt-get update
  sudo apt-get install -y powershell
else
  echo "[rayman] pwsh already installed"
fi

echo "[rayman] versions:"
(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || true)
(git --version 2>/dev/null || true)
(notify-send --version 2>/dev/null || true)
(espeak-ng --version 2>/dev/null | head -n 1 || true)

if [[ -f ./.Rayman/setup.ps1 ]] && have_cmd pwsh; then
  echo "[rayman] running setup.ps1 under WSL (safe re-run)..."
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./.Rayman/setup.ps1 || true
fi

echo "[rayman] done"
