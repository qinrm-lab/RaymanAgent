#!/usr/bin/env bash
set -euo pipefail

req="${RAYMAN_REQUIRE_SIGNATURE:-0}"
msg=".Rayman/release/manifest.txt"
sig=".Rayman/release/manifest.sig"
pub=".Rayman/release/public_key.pem"
fp=".Rayman/release/public_key.sha256"

skip_or_fail(){
  local reason="$1"
  if [[ "${req}" == "1" ]]; then
    echo "FAIL" >&2
    echo "[rayman-signature] ${reason}" >&2
    exit 2
  fi
  echo "SKIP"
  exit 0
}

[[ -f "$msg" ]] || skip_or_fail "missing manifest: $msg"
[[ -f "$sig" ]] || skip_or_fail "missing signature: $sig"
[[ -f "$pub" ]] || skip_or_fail "missing public key: $pub"
[[ -f "$fp" ]] || skip_or_fail "missing public key fingerprint: $fp"

command -v openssl >/dev/null 2>&1 || skip_or_fail "openssl not found in PATH"

expected_fp="$(tr -d '\r\n[:space:]' < "$fp" | tr '[:upper:]' '[:lower:]')"
if [[ -z "${expected_fp}" ]]; then
  echo "FAIL" >&2
  echo "[rayman-signature] empty fingerprint in $fp" >&2
  exit 2
fi

actual_fp="$(openssl pkey -pubin -in "$pub" -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | awk '{print tolower($1)}')"
if [[ -z "${actual_fp}" ]]; then
  echo "FAIL" >&2
  echo "[rayman-signature] failed to compute public key fingerprint" >&2
  exit 2
fi

if [[ "${actual_fp}" != "${expected_fp}" ]]; then
  echo "FAIL" >&2
  echo "[rayman-signature] public key fingerprint mismatch: expected=${expected_fp} actual=${actual_fp}" >&2
  exit 2
fi

if openssl pkeyutl -verify -pubin -inkey "$pub" -sigfile "$sig" -in "$msg" >/dev/null 2>&1; then
  echo "OK"
  exit 0
fi

if openssl pkeyutl -verify -rawin -pubin -inkey "$pub" -sigfile "$sig" -in "$msg" >/dev/null 2>&1; then
  echo "OK"
  exit 0
fi

echo "FAIL" >&2
exit 2
