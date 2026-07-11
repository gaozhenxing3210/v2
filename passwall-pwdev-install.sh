#!/bin/sh

set -eu

REPO_OWNER="${REPO_OWNER:-gaozhenxing3210}"
REPO_NAME="${REPO_NAME:-v2}"
REPO_BRANCH="${REPO_BRANCH:-main}"
MIRRORS="${MIRRORS:-jsdelivr ghproxy githubraw githubcom}"
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

mirror_url() {
    mirror="$1"
    path="$2"
    repo="${REPO_OWNER}/${REPO_NAME}"
    case "$mirror" in
        jsdelivr)
            printf '%s\n' "https://cdn.jsdelivr.net/gh/${repo}@${REPO_BRANCH}/${path}"
            ;;
        ghproxy)
            printf '%s\n' "https://mirror.ghproxy.com/https://raw.githubusercontent.com/${repo}/${REPO_BRANCH}/${path}"
            ;;
        githubraw)
            printf '%s\n' "https://raw.githubusercontent.com/${repo}/${REPO_BRANCH}/${path}"
            ;;
        githubcom)
            printf '%s\n' "https://github.com/${repo}/raw/${REPO_BRANCH}/${path}"
            ;;
        *)
            return 1
            ;;
    esac
}

download_from_mirrors() {
    path="$1"
    dst="$2"
    for mirror in $MIRRORS; do
        src="$(mirror_url "$mirror" "$path" || true)"
        [ -n "$src" ] || continue
        if download "$src" "$dst"; then
            echo "Using mirror: $mirror"
            return 0
        fi
    done
    return 1
}

tmp_file="/tmp/pwdev.$$"
trap 'rm -f "$tmp_file"' EXIT INT TERM

download_from_mirrors "passwall-pwdev.sh" "$tmp_file"
chmod +x "$tmp_file"
mv "$tmp_file" "$TARGET"
chmod +x "$TARGET"
"$TARGET" install

echo
echo "Installed pwdev to $TARGET"
echo "Run:"
echo "  pwdev apply-online-all PC"
