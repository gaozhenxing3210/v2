#!/bin/sh
set -eu

KIT_FILE="${KIT_FILE:-}"
KIT_URL="${KIT_URL:-}"
WORK_DIR="${WORK_DIR:-/tmp/v2raya-policy-run}"
UPLOAD_FILE="${UPLOAD_FILE:-/tmp/upload/v2raya-policy-kit.tar.gz}"

download() {
  url="$1"
  out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -L -f -o "$out" "$url"
    return $?
  fi
  echo "missing wget/curl; upload v2raya-policy-kit.tar.gz to /tmp/upload first." >&2
  return 1
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

archive="$WORK_DIR/v2raya-policy-kit.tar.gz"

if [ -n "$KIT_FILE" ]; then
  echo "Using KIT_FILE: $KIT_FILE"
  cp "$KIT_FILE" "$archive"
elif [ -f "$UPLOAD_FILE" ]; then
  echo "Using uploaded file: $UPLOAD_FILE"
  cp "$UPLOAD_FILE" "$archive"
elif [ -n "$KIT_URL" ]; then
  echo "Downloading: $KIT_URL"
  download "$KIT_URL" "$archive"
else
  echo "No package found." >&2
  echo "Upload v2raya-policy-kit.tar.gz to /tmp/upload, or run with:" >&2
  echo "KIT_URL=http://your-pc-ip:8899/v2raya-policy-kit.tar.gz sh run-local.sh" >&2
  exit 1
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
