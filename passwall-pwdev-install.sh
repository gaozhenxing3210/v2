#!/bin/sh

set -eu

REPO_OWNER="${REPO_OWNER:-gaozhenxing3210}"
REPO_NAME="${REPO_NAME:-v2}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
TARGET="/usr/bin/pwdev"

download() {
    src="$1"
    dst="$2"

    if command -v wget >/dev/null 2>&1; then
        wget -O "$dst" "$src"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$src" -o "$dst"
        return 0
    fi

    echo "Need wget or curl" >&2
    exit 1
}

tmp_file="/tmp/pwdev.$$"
trap 'rm -f "$tmp_file"' EXIT INT TERM

download "${RAW_BASE}/passwall-pwdev.sh" "$tmp_file"
chmod +x "$tmp_file"
mv "$tmp_file" "$TARGET"
chmod +x "$TARGET"
"$TARGET" install

echo
echo "Installed pwdev to $TARGET"
echo "Run:"
echo "  pwdev apply-online-all PC"
