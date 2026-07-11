#!/bin/sh
set -eu

REPO="${REPO:-gaozhenxing3210/v2}"
BRANCH="${BRANCH:-main}"
WORK_DIR="${WORK_DIR:-/tmp/pwdev-onekey}"
SCRIPT_URL="${SCRIPT_URL:-}"
DNS_SERVERS="${DNS_SERVERS:-223.5.5.5 119.29.29.29 1.1.1.1}"
AUTO_APPLY="${AUTO_APPLY:-0}"
PREFIX="${PREFIX:-PC}"
UPSTREAM_IP="${UPSTREAM_IP:-}"
UPSTREAM_PORT="${UPSTREAM_PORT:-}"

boost_dns() {
  mkdir -p /tmp/resolv.conf.d
  tmp_dns="/tmp/resolv.conf.d/resolv.conf.auto"
  : > "$tmp_dns"
  for ns in $DNS_SERVERS; do
    printf 'nameserver %s\n' "$ns" >> "$tmp_dns"
  done
  ln -sf "$tmp_dns" /tmp/resolv.conf
}

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

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
script="$WORK_DIR/pwdev-install.sh"
boost_dns || true

if [ -n "$SCRIPT_URL" ]; then
  download "$SCRIPT_URL" "$script"
else
  ok=0
  for url in \
    "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/passwall-pwdev-install.sh" \
    "https://raw.githubusercontent.com/$REPO/$BRANCH/passwall-pwdev-install.sh" \
    "https://github.com/$REPO/raw/$BRANCH/passwall-pwdev-install.sh"
  do
    if download "$url" "$script"; then
      ok=1
      break
    fi
  done
  if [ "$ok" != "1" ]; then
    echo "download failed from all GitHub URLs." >&2
    exit 1
  fi
fi

chmod +x "$script"
sh "$script"

if [ "$AUTO_APPLY" = "1" ]; then
  if [ -n "$UPSTREAM_IP" ]; then
    if [ -n "$UPSTREAM_PORT" ]; then
      pwdev apply-online-all "$PREFIX" "$UPSTREAM_IP" "$UPSTREAM_PORT"
    else
      pwdev apply-online-all "$PREFIX" "$UPSTREAM_IP"
    fi
  else
    pwdev apply-online-all "$PREFIX"
  fi
fi
