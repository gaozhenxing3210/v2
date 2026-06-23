#!/bin/sh
set -eu

REPO="${REPO:-gaozhenxing3210/v2}"
BRANCH="${BRANCH:-main}"
WORK_DIR="${WORK_DIR:-/tmp/v2raya-policy-onekey}"
KIT_URL="${KIT_URL:-}"

# One-key installs should reproduce the same v2rayA account/nodes DB by default.
# Device MAC/IP bindings stay disabled unless explicitly requested.
# DNS is hijacked through the router by default, so each client keeps following
# its current direct/devXX strategy even for UDP/TCP 53 traffic.
RESTORE_V2RAYA_DB="${RESTORE_V2RAYA_DB:-1}"
RESTORE_DEVICE_MAP="${RESTORE_DEVICE_MAP:-0}"
ENABLE_DNS_POLICY="${ENABLE_DNS_POLICY:-1}"
DNS_HIJACK_PRIMARY="${DNS_HIJACK_PRIMARY:-1.1.1.1}"
DNS_HIJACK_SECONDARY="${DNS_HIJACK_SECONDARY:-8.8.8.8}"
ENABLE_BBR="${ENABLE_BBR:-1}"
OPTIMIZE_ROUTER="${OPTIMIZE_ROUTER:-1}"
OPTIMIZE_WIFI="${OPTIMIZE_WIFI:-1}"
LEAN_SERVICES="${LEAN_SERVICES:-1}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
SET_WIFI_PASSWORD="${SET_WIFI_PASSWORD:-1}"
WIFI_PASSWORD="${WIFI_PASSWORD:-88888888}"
OPTIMIZE_THERMAL="${OPTIMIZE_THERMAL:-1}"
ENABLE_88FRP="${ENABLE_88FRP:-0}"
FRP_VERSION="${FRP_VERSION:-0.69.1}"
FRP_SERVER_ADDR="${FRP_SERVER_ADDR:-}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-1210}"
FRP_USER="${FRP_USER:-}"
FRP_PROXY_NAME="${FRP_PROXY_NAME:-}"
FRP_LOCAL_IP="${FRP_LOCAL_IP:-auto}"
FRP_LOCAL_PORT="${FRP_LOCAL_PORT:-}"
FRP_REMOTE_PORT="${FRP_REMOTE_PORT:-}"
FRP_USE_ENCRYPTION="${FRP_USE_ENCRYPTION:-1}"
FRP_USE_COMPRESSION="${FRP_USE_COMPRESSION:-1}"
PANEL_88FRP_SLOT="${PANEL_88FRP_SLOT:-}"
PANEL_88FRP_PORT_BASE="${PANEL_88FRP_PORT_BASE:-60887}"
PANEL_88FRP_NAME_PREFIX="${PANEL_88FRP_NAME_PREFIX:-panel}"
export RESTORE_V2RAYA_DB RESTORE_DEVICE_MAP ENABLE_DNS_POLICY DNS_HIJACK_PRIMARY DNS_HIJACK_SECONDARY ENABLE_BBR OPTIMIZE_ROUTER OPTIMIZE_WIFI LEAN_SERVICES DISABLE_IPV6 SET_WIFI_PASSWORD WIFI_PASSWORD OPTIMIZE_THERMAL ENABLE_88FRP FRP_VERSION FRP_SERVER_ADDR FRP_SERVER_PORT FRP_USER FRP_PROXY_NAME FRP_LOCAL_IP FRP_LOCAL_PORT FRP_REMOTE_PORT FRP_USE_ENCRYPTION FRP_USE_COMPRESSION PANEL_88FRP_SLOT PANEL_88FRP_PORT_BASE PANEL_88FRP_NAME_PREFIX

download() {
  url="$1"
  out="$2"
  echo "Downloading: $url"
  if command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -L -f -o "$out" "$url"
    return $?
  fi
  echo "missing wget/curl; cannot download package." >&2
  return 1
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
archive="$WORK_DIR/v2raya-policy-kit.tar.gz"

if [ -n "$KIT_URL" ]; then
  download "$KIT_URL" "$archive"
else
  ok=0
  for url in \
    "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/dist/v2raya-policy-kit.tar.gz" \
    "https://raw.githubusercontent.com/$REPO/$BRANCH/dist/v2raya-policy-kit.tar.gz"
  do
    if download "$url" "$archive"; then
      ok=1
      break
    fi
  done
  if [ "$ok" != "1" ]; then
    echo "download failed from all GitHub URLs." >&2
    exit 1
  fi
fi

echo "Extracting package ..."
tar -xzf "$archive" -C "$WORK_DIR"

install_file="$(find "$WORK_DIR" -path '*/v2raya-policy-kit/install.sh' -type f 2>/dev/null | head -n 1 || true)"
if [ -z "$install_file" ]; then
  install_file="$(find "$WORK_DIR" -maxdepth 4 -type f -name install.sh 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$install_file" ]; then
  echo "install.sh not found after extracting package." >&2
  exit 1
fi

echo "Running installer: $install_file"
cd "$(dirname "$install_file")"
sh install.sh
