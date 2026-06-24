#!/bin/sh
set -eu

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
KIT_URL="${KIT_URL:-}"
BOOTSTRAP_TMP="${BOOTSTRAP_TMP:-/tmp/v2raya-policy-bootstrap}"

download() {
  url="$1"
  out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -4 --timeout=20 --tries=1 -O "$out" "$url"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -4 -L -f --connect-timeout 20 --max-time 300 -o "$out" "$url"
    return $?
  fi
  echo "missing wget/curl; cannot download $url" >&2
  return 1
}

if [ -z "$KIT_URL" ]; then
  if [ -z "$GITHUB_REPO" ]; then
    echo "Set GITHUB_REPO=owner/repo or KIT_URL=https://.../v2raya-policy-kit.tar.gz" >&2
    exit 1
  fi
  KIT_URL="https://cdn.jsdelivr.net/gh/$GITHUB_REPO@$GITHUB_BRANCH/dist/v2raya-policy-kit.tar.gz"
fi

rm -rf "$BOOTSTRAP_TMP"
mkdir -p "$BOOTSTRAP_TMP"

archive="$BOOTSTRAP_TMP/package.tar.gz"
echo "Downloading: $KIT_URL"
download "$KIT_URL" "$archive"

echo "Extracting package ..."
if ! tar -xzf "$archive" -C "$BOOTSTRAP_TMP" 2>/dev/null; then
  tar -xf "$archive" -C "$BOOTSTRAP_TMP"
fi

install_file="$(find "$BOOTSTRAP_TMP" -path '*/v2raya-policy-kit/install.sh' -type f 2>/dev/null | head -n 1 || true)"
if [ -z "$install_file" ]; then
  install_file="$(find "$BOOTSTRAP_TMP" -maxdepth 3 -type f -name install.sh 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$install_file" ]; then
  echo "install.sh not found in downloaded package." >&2
  exit 1
fi

kit_dir="$(dirname "$install_file")"
echo "Running installer from: $kit_dir"
cd "$kit_dir"
sh install.sh
