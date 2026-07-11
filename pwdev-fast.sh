#!/bin/sh
set -eu

REPO="${REPO:-gaozhenxing3210/v2}"
BRANCH="${BRANCH:-main}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-}"
WORK_DIR="${WORK_DIR:-/tmp/pwdev-fast}"
MIRRORS="${MIRRORS:-jsdelivr ghproxy githubraw githubcom}"

download() {
  url="$1"
  out="$2"
  echo "Downloading: $url"
  if command -v wget >/dev/null 2>&1; then
    wget -4 --timeout=20 --tries=1 -O "$out" "$url"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -4 -L -f --connect-timeout 20 --max-time 300 -o "$out" "$url"
    return $?
  fi
  echo "missing wget/curl; cannot download script." >&2
  return 1
}

mirror_url() {
  mirror="$1"
  path="$2"
  case "$mirror" in
    jsdelivr)
      printf '%s\n' "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/$path"
      ;;
    ghproxy)
      printf '%s\n' "https://mirror.ghproxy.com/https://raw.githubusercontent.com/$REPO/$BRANCH/$path"
      ;;
    githubraw)
      printf '%s\n' "https://raw.githubusercontent.com/$REPO/$BRANCH/$path"
      ;;
    githubcom)
      printf '%s\n' "https://github.com/$REPO/raw/$BRANCH/$path"
      ;;
    *)
      return 1
      ;;
  esac
}

download_bootstrap() {
  out="$1"
  if [ -n "$BOOTSTRAP_URL" ]; then
    download "$BOOTSTRAP_URL" "$out"
    return $?
  fi
  for mirror in $MIRRORS; do
    url="$(mirror_url "$mirror" "pwdev-onekey.sh" || true)"
    [ -n "$url" ] || continue
    if download "$url" "$out"; then
      echo "Using mirror: $mirror"
      return 0
    fi
  done
  return 1
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
script="$WORK_DIR/pwdev-onekey.sh"

if ! download_bootstrap "$script"; then
  echo "download failed from all mirrors." >&2
  exit 1
fi

chmod +x "$script"
sh "$script" "$@"
