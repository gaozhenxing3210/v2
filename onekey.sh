#!/bin/sh
set -eu

REPO="${REPO:-gaozhenxing3210/v2}"
BRANCH="${BRANCH:-main}"
WORK_DIR="${WORK_DIR:-/tmp/v2raya-policy-onekey}"
KIT_URL="${KIT_URL:-}"

# One-key installs should reproduce the same v2rayA account/nodes DB by default.
# Device MAC/IP bindings stay disabled unless explicitly requested.
RESTORE_V2RAYA_DB="${RESTORE_V2RAYA_DB:-1}"
RESTORE_DEVICE_MAP="${RESTORE_DEVICE_MAP:-0}"
ENABLE_BBR="${ENABLE_BBR:-1}"
OPTIMIZE_ROUTER="${OPTIMIZE_ROUTER:-1}"
OPTIMIZE_WIFI="${OPTIMIZE_WIFI:-1}"
LEAN_SERVICES="${LEAN_SERVICES:-1}"
export RESTORE_V2RAYA_DB RESTORE_DEVICE_MAP ENABLE_BBR OPTIMIZE_ROUTER OPTIMIZE_WIFI LEAN_SERVICES

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
