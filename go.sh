#!/bin/sh
set -eu

REPO="${REPO:-gaozhenxing3210/v2}"
BRANCH="${BRANCH:-main}"
ONEKEY_URL="${ONEKEY_URL:-}"
DNS_SERVERS="${DNS_SERVERS:-223.5.5.5 119.29.29.29 1.1.1.1}"
TMP_SCRIPT="${TMP_SCRIPT:-/tmp/v2raya-go-onekey.sh}"

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

boost_dns || true

rm -f "$TMP_SCRIPT"
ok=0

if [ -n "$ONEKEY_URL" ]; then
  download "$ONEKEY_URL" "$TMP_SCRIPT" && ok=1
else
  for url in \
    "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/onekey.sh" \
    "https://fastly.jsdelivr.net/gh/$REPO@$BRANCH/onekey.sh" \
    "https://raw.githubusercontent.com/$REPO/$BRANCH/onekey.sh"
  do
    if download "$url" "$TMP_SCRIPT"; then
      ok=1
      break
    fi
  done
fi

[ "$ok" = "1" ] || {
  echo "download failed from all script URLs." >&2
  exit 1
}

sh "$TMP_SCRIPT"
