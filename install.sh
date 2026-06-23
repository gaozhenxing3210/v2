#!/bin/sh
set -eu

PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-weifeng}"
V2RAYA_USER="${V2RAYA_USER:-admin}"
V2RAYA_PASS="${V2RAYA_PASS:-weifeng}"
SET_ROOT_PASSWORD="${SET_ROOT_PASSWORD:-1}"
ROOT_PASSWORD="${ROOT_PASSWORD:-1}"
ENABLE_BOOT_START="${ENABLE_BOOT_START:-1}"

RESTORE_V2RAYA_DB="${RESTORE_V2RAYA_DB:-0}"
RESTORE_DEVICE_MAP="${RESTORE_DEVICE_MAP:-0}"
RESTORE_FULL="${RESTORE_FULL:-0}"
RESET_DEVICE_MAP="${RESET_DEVICE_MAP:-0}"

INSTALL_V2RAYA="${INSTALL_V2RAYA:-1}"
INSTALL_OFFLINE_IPKS="${INSTALL_OFFLINE_IPKS:-auto}"
INSTALL_DNSMASQ_FULL="${INSTALL_DNSMASQ_FULL:-0}"
ENABLE_8088_ENTRY="${ENABLE_8088_ENTRY:-1}"
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

[ "$RESTORE_FULL" = "1" ] && {
  RESTORE_V2RAYA_DB=1
  RESTORE_DEVICE_MAP=1
}

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || {
  echo "Cannot find install script directory." >&2
  exit 1
}
cd "$SCRIPT_DIR"

run_timeout() {
  seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

need_file() {
  [ -f "$1" ] || {
    echo "missing file: $1" >&2
    exit 1
  }
}

opkg_update_once() {
  [ "${OPKG_UPDATED:-0}" = "1" ] && return 0
  OPKG_UPDATED=1
  if command -v opkg >/dev/null 2>&1; then
    run_timeout 45 opkg update || true
  fi
}

install_local_ipks() {
  [ -d ipks ] || return 1
  ipk_files="$(find ipks -type f -name '*.ipk' 2>/dev/null | sort || true)"
  [ -n "$ipk_files" ] || return 1
  echo "Installing bundled IPK files from ./ipks ..."
  # shellcheck disable=SC2086
  opkg install $ipk_files || true
  return 0
}

install_local_ipks_by_pattern() {
  pattern="$1"
  [ -d ipks ] || return 1
  ipk_files="$(find ipks -type f -name "$pattern" 2>/dev/null | sort || true)"
  [ -n "$ipk_files" ] || return 1
  echo "Installing bundled IPK files matching $pattern ..."
  # shellcheck disable=SC2086
  opkg install $ipk_files || true
  return 0
}

install_local_data_ipks() {
  install_local_ipks_by_pattern 'v2ray-geo*.ipk'
}

install_local_v2raya_ipks() {
  [ -d ipks ] || return 1
  ipk_files="$(find ipks -type f \( -name 'v2raya_*.ipk' -o -name 'luci-app-v2raya_*.ipk' -o -name 'luci-i18n-v2raya-zh-cn_*.ipk' \) 2>/dev/null | sort || true)"
  [ -n "$ipk_files" ] || return 1
  echo "Installing bundled v2rayA IPK files ..."
  # shellcheck disable=SC2086
  opkg install $ipk_files || true
  return 0
}

install_opkg_packages() {
  command -v opkg >/dev/null 2>&1 || return 1
  opkg_update_once
  for pkg in "$@"; do
    [ -n "$pkg" ] || continue
    opkg list-installed "$pkg" 2>/dev/null | grep -q "^$pkg " && continue
    run_timeout 120 opkg install "$pkg" || echo "warning: opkg install failed: $pkg" >&2
  done
}

opkg_has_pkg() {
  command -v opkg >/dev/null 2>&1 || return 1
  pkg="$1"
  opkg list "$pkg" 2>/dev/null | grep -q "^$pkg - "
}

install_apk_packages() {
  command -v apk >/dev/null 2>&1 || return 1
  apk update || true
  apk add "$@" || true
}

decode_base64_file() {
  src="$1"
  dst="$2"
  if command -v base64 >/dev/null 2>&1; then
    base64 -d "$src" >"$dst"
    return $?
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl base64 -d -A -in "$src" -out "$dst"
    return $?
  fi
  if command -v lua >/dev/null 2>&1; then
    lua - "$src" "$dst" <<'LUA'
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local map = {}
for i = 1, #alphabet do map[alphabet:sub(i,i)] = i - 1 end
local src, dst = arg[1], arg[2]
local f = assert(io.open(src, "r"))
local s = f:read("*a") or ""
f:close()
s = s:gsub("%s+", "")
local out = {}
for i = 1, #s, 4 do
  local c1, c2, c3, c4 = s:sub(i,i), s:sub(i+1,i+1), s:sub(i+2,i+2), s:sub(i+3,i+3)
  local b1, b2 = map[c1], map[c2]
  if not b1 or not b2 then break end
  local b3, b4 = map[c3], map[c4]
  local n = b1 * 262144 + b2 * 4096 + (b3 or 0) * 64 + (b4 or 0)
  out[#out+1] = string.char(math.floor(n / 65536) % 256)
  if c3 ~= "=" and b3 then out[#out+1] = string.char(math.floor(n / 256) % 256) end
  if c4 ~= "=" and b4 then out[#out+1] = string.char(n % 256) end
end
f = assert(io.open(dst, "wb"))
f:write(table.concat(out))
f:close()
LUA
    return $?
  fi
  echo "Cannot decode base64: install base64, openssl, or lua." >&2
  return 1
}

download_file() {
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
  echo "missing wget/curl; cannot download $url" >&2
  return 1
}

install_packages() {
  [ "$INSTALL_V2RAYA" = "1" ] || return 0

  if command -v opkg >/dev/null 2>&1; then
    opkg_update_once

    base_pkgs="curl jsonfilter lua luci-lib-jsonc kmod-tcp-bbr"
    [ "$INSTALL_DNSMASQ_FULL" = "1" ] && base_pkgs="$base_pkgs dnsmasq-full"
    # shellcheck disable=SC2086
    install_opkg_packages $base_pkgs || true

    if [ "$INSTALL_OFFLINE_IPKS" = "1" ]; then
      install_local_ipks || true
    else
      install_local_data_ipks || install_opkg_packages v2ray-geoip v2ray-geosite || true
    fi

    v2raya_repo_ok=0
    if opkg_has_pkg v2raya && opkg_has_pkg xray-core; then
      v2raya_repo_ok=1
    fi

    if [ "$v2raya_repo_ok" = "1" ]; then
      repo_pkgs="xray-core v2raya"
      opkg_has_pkg luci-app-v2raya && repo_pkgs="$repo_pkgs luci-app-v2raya"
      opkg_has_pkg luci-i18n-v2raya-zh-cn && repo_pkgs="$repo_pkgs luci-i18n-v2raya-zh-cn"
      opkg_has_pkg iptables-mod-conntrack-extra && repo_pkgs="$repo_pkgs iptables-mod-conntrack-extra"
      opkg_has_pkg iptables-mod-extra && repo_pkgs="$repo_pkgs iptables-mod-extra"
      opkg_has_pkg iptables-mod-filter && repo_pkgs="$repo_pkgs iptables-mod-filter"
      opkg_has_pkg iptables-mod-tproxy && repo_pkgs="$repo_pkgs iptables-mod-tproxy"
      opkg_has_pkg kmod-ipt-nat6 && repo_pkgs="$repo_pkgs kmod-ipt-nat6"
      # shellcheck disable=SC2086
      install_opkg_packages $repo_pkgs || true
    else
      install_local_v2raya_ipks || true
    fi

    for pkg in kmod-nft-tproxy kmod-nft-socket iptables-mod-socket; do
      opkg_has_pkg "$pkg" || continue
      install_opkg_packages "$pkg" || true
    done

    if ! command -v v2raya >/dev/null 2>&1 && [ "$INSTALL_OFFLINE_IPKS" != "0" ]; then
      install_local_v2raya_ipks || true
    fi
    return 0
  fi

  if command -v apk >/dev/null 2>&1; then
    install_apk_packages v2raya xray curl jsonfilter lua || true
    return 0
  fi

  echo "warning: no opkg/apk found; package installation skipped." >&2
}

install_frpc_runtime() {
  if [ -n "$PANEL_88FRP_SLOT" ]; then
    ENABLE_88FRP=1
    [ -n "$FRP_SERVER_ADDR" ] || FRP_SERVER_ADDR="39.106.200.1"
    [ -n "$FRP_SERVER_PORT" ] || FRP_SERVER_PORT="1210"
    [ -n "$FRP_USER" ] || FRP_USER="SnjBdxM4UqgN"
    [ -n "$FRP_PROXY_NAME" ] || FRP_PROXY_NAME="${PANEL_88FRP_NAME_PREFIX}-$(printf '%02d' "$PANEL_88FRP_SLOT")"
    [ -n "$FRP_REMOTE_PORT" ] || FRP_REMOTE_PORT="$((PANEL_88FRP_PORT_BASE + PANEL_88FRP_SLOT))"
    [ -n "$FRP_LOCAL_PORT" ] || FRP_LOCAL_PORT="8088"
  fi

  [ "$ENABLE_88FRP" = "1" ] || return 0

  [ -n "$FRP_SERVER_ADDR" ] || { echo "ENABLE_88FRP=1 时必须提供 FRP_SERVER_ADDR" >&2; return 1; }
  [ -n "$FRP_USER" ] || { echo "ENABLE_88FRP=1 时必须提供 FRP_USER" >&2; return 1; }
  [ -n "$FRP_PROXY_NAME" ] || { echo "ENABLE_88FRP=1 时必须提供 FRP_PROXY_NAME" >&2; return 1; }
  [ -n "$FRP_REMOTE_PORT" ] || { echo "ENABLE_88FRP=1 时必须提供 FRP_REMOTE_PORT" >&2; return 1; }
  [ -n "$FRP_LOCAL_PORT" ] || FRP_LOCAL_PORT="22"

  if ! command -v frpc >/dev/null 2>&1; then
    install_opkg_packages frpc || true
    if ! command -v frpc >/dev/null 2>&1; then
      install_apk_packages frpc || true
    fi
  fi

  if ! command -v frpc >/dev/null 2>&1; then
    arch="$(uname -m 2>/dev/null || echo unknown)"
    case "$arch" in
      aarch64|arm64) frp_arch="arm64" ;;
      x86_64|amd64) frp_arch="amd64" ;;
      armv7l|armv7|armhf) frp_arch="arm_hf" ;;
      armv6l|arm) frp_arch="arm" ;;
      mips64) frp_arch="mips64" ;;
      mips) frp_arch="mips" ;;
      loongarch64|loong64) frp_arch="loong64" ;;
      *)
        echo "unsupported arch for official frpc binary: $arch" >&2
        return 1
        ;;
    esac
    tmp_dir="/tmp/frpc-install.$$"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    tarball="$tmp_dir/frp.tar.gz"
    url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${frp_arch}.tar.gz"
    echo "Downloading official frpc: $url"
    download_file "$url" "$tarball"
    tar -xzf "$tarball" -C "$tmp_dir"
    frpc_bin="$(find "$tmp_dir" -type f -name frpc 2>/dev/null | head -n 1 || true)"
    [ -n "$frpc_bin" ] || { echo "frpc binary not found after extract" >&2; rm -rf "$tmp_dir"; return 1; }
    mkdir -p /usr/bin
    cp "$frpc_bin" /usr/bin/frpc
    chmod 0755 /usr/bin/frpc
    rm -rf "$tmp_dir"
  fi

  command -v frpc >/dev/null 2>&1 || { echo "frpc install failed" >&2; return 1; }

  mkdir -p /etc/frp
  frp_local_ip="$FRP_LOCAL_IP"
  if [ -z "$frp_local_ip" ] || [ "$frp_local_ip" = "auto" ]; then
    ssh_bind="$(netstat -lnt 2>/dev/null | awk '$4 ~ /:22$/ {print $4; exit}' || true)"
    case "$ssh_bind" in
      0.0.0.0:22|127.0.0.1:22|[::]:22|:::22|\*:22)
        frp_local_ip="127.0.0.1"
        ;;
      *:22)
        frp_local_ip="${ssh_bind%:22}"
        ;;
      *)
        frp_local_ip="$(lan_ip)"
        ;;
    esac
  fi
  frpc_ver="$(frpc -v 2>/dev/null | head -n 1 | tr -d '\r' || echo 0.0.0)"
  frpc_minor="$(printf '%s' "$frpc_ver" | awk -F. '{print ($2 ~ /^[0-9]+$/ ? $2 : 0)}')"
  config_path="/etc/frp/frpc.toml"
  if [ "$frpc_minor" -lt 52 ]; then
    config_path="/etc/frp/frpc.ini"
    cat >"$config_path" <<EOF
[common]
server_addr = ${FRP_SERVER_ADDR}
server_port = ${FRP_SERVER_PORT}
user = ${FRP_USER}
login_fail_exit = false

[${FRP_PROXY_NAME}]
type = tcp
local_ip = ${frp_local_ip}
local_port = ${FRP_LOCAL_PORT}
remote_port = ${FRP_REMOTE_PORT}
use_encryption = $( [ "$FRP_USE_ENCRYPTION" = "1" ] && echo true || echo false )
use_compression = $( [ "$FRP_USE_COMPRESSION" = "1" ] && echo true || echo false )
EOF
  else
    cat >"$config_path" <<EOF
serverAddr = "${FRP_SERVER_ADDR}"
serverPort = ${FRP_SERVER_PORT}
user = "${FRP_USER}"
loginFailExit = false

[[proxies]]
type = "tcp"
name = "${FRP_PROXY_NAME}"
localIP = "${frp_local_ip}"
localPort = ${FRP_LOCAL_PORT}
remotePort = ${FRP_REMOTE_PORT}
transport.useEncryption = $( [ "$FRP_USE_ENCRYPTION" = "1" ] && echo true || echo false )
transport.useCompression = $( [ "$FRP_USE_COMPRESSION" = "1" ] && echo true || echo false )
EOF
  fi

  disable_service_if_present frpc || true

  cat >/etc/init.d/frpc88 <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/frpc -c __CONFIG_PATH__
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
  sed -i "s|__CONFIG_PATH__|$config_path|g" /etc/init.d/frpc88
  chmod +x /etc/init.d/frpc88

  /usr/bin/frpc verify -c "$config_path" >/tmp/frpc88-verify.log 2>&1 || {
    echo "frpc verify failed, see /tmp/frpc88-verify.log" >&2
    return 1
  }

  /etc/init.d/frpc88 enable >/dev/null 2>&1 || true
  /etc/init.d/frpc88 restart >/dev/null 2>&1 || /etc/init.d/frpc88 start >/dev/null 2>&1 || true
  return 0
}

ensure_geo_symlinks() {
  mkdir -p /usr/share/xray /usr/share/v2ray
  [ -f /usr/share/v2ray/geoip.dat ] && [ ! -f /usr/share/xray/geoip.dat ] && ln -sf /usr/share/v2ray/geoip.dat /usr/share/xray/geoip.dat
  [ -f /usr/share/v2ray/geosite.dat ] && [ ! -f /usr/share/xray/geosite.dat ] && ln -sf /usr/share/v2ray/geosite.dat /usr/share/xray/geosite.dat
  [ -f /usr/share/xray/geoip.dat ] && [ ! -f /usr/share/v2ray/geoip.dat ] && ln -sf /usr/share/xray/geoip.dat /usr/share/v2ray/geoip.dat
  [ -f /usr/share/xray/geosite.dat ] && [ ! -f /usr/share/v2ray/geosite.dat ] && ln -sf /usr/share/xray/geosite.dat /usr/share/v2ray/geosite.dat
  return 0
}

service_exists() {
  [ -x "/etc/init.d/$1" ]
}

choose_qdisc() {
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if modprobe sch_fq >/dev/null 2>&1; then
    echo "fq"
    return 0
  fi
  if [ -n "$current_qdisc" ]; then
    echo "$current_qdisc"
    return 0
  fi
  echo "fq_codel"
}

port_listening() {
  port="$1"
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" { found=1 } END { exit(found ? 0 : 1) }'
    return $?
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" { found=1 } END { exit(found ? 0 : 1) }'
    return $?
  fi
  return 1
}

api_login_token() {
  [ -n "${V2RAYA_USER:-}" ] || return 1
  [ -n "${V2RAYA_PASS:-}" ] || return 1
  tmp_login="/tmp/v2raya-installer-login.$$"
  tmp_resp="/tmp/v2raya-installer-login-resp.$$"
  lua - "$V2RAYA_USER" "$V2RAYA_PASS" >"$tmp_login" <<'LUA'
local json = require "luci.jsonc"
print(json.stringify({ username = arg[1] or "", password = arg[2] or "" }))
LUA
  curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @"$tmp_login" http://127.0.0.1:2017/api/login >"$tmp_resp" 2>/dev/null || {
    rm -f "$tmp_login" "$tmp_resp"
    return 1
  }
  jsonfilter -q -i "$tmp_resp" -e '@.data.token' 2>/dev/null || true
  rm -f "$tmp_login" "$tmp_resp"
}

api_register_token() {
  [ -n "${V2RAYA_USER:-}" ] || return 1
  [ -n "${V2RAYA_PASS:-}" ] || return 1
  tmp_reg="/tmp/v2raya-installer-register.$$"
  tmp_resp="/tmp/v2raya-installer-register-resp.$$"
  lua - "$V2RAYA_USER" "$V2RAYA_PASS" >"$tmp_reg" <<'LUA'
local json = require "luci.jsonc"
print(json.stringify({ username = arg[1] or "", password = arg[2] or "" }))
LUA
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' --data-binary @"$tmp_reg" http://127.0.0.1:2017/api/account >"$tmp_resp" 2>/dev/null || {
    rm -f "$tmp_reg" "$tmp_resp"
    return 1
  }
  jsonfilter -q -i "$tmp_resp" -e '@.data.token' 2>/dev/null || true
  rm -f "$tmp_reg" "$tmp_resp"
}

disable_service_if_present() {
  svc="$1"
  service_exists "$svc" || return 0
  /etc/init.d/"$svc" stop >/dev/null 2>&1 || true
  /etc/init.d/"$svc" disable >/dev/null 2>&1 || true
}

ensure_access_services_runtime() {
  service_exists dropbear && /etc/init.d/dropbear enable >/dev/null 2>&1 || true
  service_exists dropbear && /etc/init.d/dropbear status >/dev/null 2>&1 || /etc/init.d/dropbear start >/dev/null 2>&1 || true
  service_exists ttyd && /etc/init.d/ttyd enable >/dev/null 2>&1 || true
  service_exists ttyd && /etc/init.d/ttyd status >/dev/null 2>&1 || /etc/init.d/ttyd start >/dev/null 2>&1 || true
}

set_root_password_runtime() {
  [ "$SET_ROOT_PASSWORD" = "1" ] || return 0
  if command -v chpasswd >/dev/null 2>&1; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
    return $?
  fi
  printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd root >/dev/null 2>&1
}

ensure_v2raya_running() {
  service_exists v2raya || {
    echo "warning: /etc/init.d/v2raya not found; v2rayA package may not be installed." >&2
    return 1
  }

  uci set v2raya.config.enabled='1' 2>/dev/null || true
  uci commit v2raya 2>/dev/null || true
  /etc/init.d/v2raya enable >/dev/null 2>&1 || true

  log_file="/tmp/v2raya-install-start.log"
  : >"$log_file"

  attempt=1
  while [ "$attempt" -le 3 ]; do
    echo "[v2rayA start attempt $attempt]" >>"$log_file"
    /etc/init.d/v2raya restart >>"$log_file" 2>&1 || /etc/init.d/v2raya start >>"$log_file" 2>&1 || true
    sleep 2
    if /etc/init.d/v2raya status >/dev/null 2>&1 && port_listening 2017; then
      echo "v2rayA started successfully on attempt $attempt" >>"$log_file"
      return 0
    fi
    /etc/init.d/v2raya status >>"$log_file" 2>&1 || true
    logread 2>/dev/null | tail -n 80 | grep -i v2raya >>"$log_file" 2>&1 || true
    attempt=$((attempt + 1))
    sleep 2
  done

  echo "v2rayA failed to reach running+listening state after retries." >>"$log_file"
  return 1
}

ensure_uhttpd_8088() {
  [ "$ENABLE_8088_ENTRY" = "1" ] || return 0

  uci -q del_list uhttpd.main.listen_http='0.0.0.0:8088' || true
  uci -q del_list uhttpd.main.listen_http='[::]:8088' || true
  uci -q delete uhttpd.v2raya_policy_entry || true
  uci set uhttpd.v2raya_policy_entry='uhttpd'
  uci add_list uhttpd.v2raya_policy_entry.listen_http='0.0.0.0:8088'
  uci set uhttpd.v2raya_policy_entry.home='/www-v2raya-policy'
  uci set uhttpd.v2raya_policy_entry.index_page='index.html'
  uci set uhttpd.v2raya_policy_entry.cgi_prefix='/cgi-bin'
  uci set uhttpd.v2raya_policy_entry.script_timeout='60'
  uci set uhttpd.v2raya_policy_entry.network_timeout='30'
  uci set uhttpd.v2raya_policy_entry.http_keepalive='20'
  uci set uhttpd.v2raya_policy_entry.tcp_keepalive='1'
  uci commit uhttpd 2>/dev/null || true

  /etc/init.d/uhttpd enable >/dev/null 2>&1 || true
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || /etc/init.d/uhttpd start >/dev/null 2>&1 || true
  sleep 2

  port_listening 8088
}

verify_wifi_password() {
  [ "$SET_WIFI_PASSWORD" = "1" ] || return 0
  uci show wireless >/dev/null 2>&1 || return 0

  for section in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
    mode="$(uci -q get wireless.$section.mode 2>/dev/null || true)"
    [ -n "$mode" ] || mode='ap'
    [ "$mode" = "ap" ] || continue
    key="$(uci -q get wireless.$section.key || true)"
    enc="$(uci -q get wireless.$section.encryption || true)"
    disabled="$(uci -q get wireless.$section.disabled || true)"
    [ "$key" = "$WIFI_PASSWORD" ] || return 1
    [ "$disabled" != "1" ] || return 1
    [ -n "$enc" ] || return 1
  done
  return 0
}

flush_ipv6_runtime() {
  for dev in $(ls /proc/sys/net/ipv6/conf 2>/dev/null | grep -v '^all$' | grep -v '^default$' || true); do
    sysctl -w "net.ipv6.conf.$dev.disable_ipv6=1" >/dev/null 2>&1 || true
    ip -6 addr flush dev "$dev" >/dev/null 2>&1 || true
  done
  ifdown wan6 >/dev/null 2>&1 || true
}

verify_ipv6_disabled() {
  [ "$DISABLE_IPV6" = "1" ] || return 0

  [ -z "$(uci -q get network.wan6.proto || true)" ] || return 1
  [ "$(uci -q get network.lan.delegate || true)" = "0" ] || return 1
  [ "$(uci -q get network.lan.ip6assign || true)" = "0" ] || return 1
  [ "$(uci -q get dhcp.lan.ra || true)" = "disabled" ] || return 1
  [ "$(uci -q get dhcp.lan.dhcpv6 || true)" = "disabled" ] || return 1
  [ "$(uci -q get dhcp.lan.ndp || true)" = "disabled" ] || return 1
  [ "$(uci -q get dhcp.lan.ra_management || true)" = "0" ] || return 1
  service_exists odhcpd && [ -L /etc/rc.d/S95odhcpd ] && return 1
  return 0
}

verify_v2raya_login() {
  token="$(api_login_token || true)"
  [ -n "$token" ]
}

ensure_v2raya_account() {
  token="$(api_login_token || true)"
  [ -n "$token" ] && return 0

  token="$(api_register_token || true)"
  [ -n "$token" ] && return 0

  token="$(api_login_token || true)"
  [ -n "$token" ]
}

optimize_router_runtime() {
  [ "$OPTIMIZE_ROUTER" = "1" ] || return 0

  mkdir -p /etc/sysctl.d /etc/modules.d
  modprobe tcp_bbr 2>/dev/null || true
  qdisc="$(choose_qdisc)"

  {
    echo "tcp_bbr"
    [ "$qdisc" = "fq" ] && echo "sch_fq"
  } >/etc/modules.d/92-v2raya-performance

  cat >/etc/sysctl.d/92-v2raya-performance.conf <<'EOF'
net.core.default_qdisc=__QDISC__
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.netfilter.nf_conntrack_tcp_be_liberal=1
EOF
  sed -i "s/__QDISC__/$qdisc/g" /etc/sysctl.d/92-v2raya-performance.conf
  sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1 || true

  uci -q set network.globals=globals || true
  uci -q set network.globals.packet_steering='1' || true
  uci -q set firewall.@defaults[0].flow_offloading='1' || true
  uci -q set firewall.@defaults[0].flow_offloading_hw='1' || true
  uci -q set system.@system[0].log_size='64' || true
  uci -q set system.@system[0].conloglevel='5' || true
  uci commit network 2>/dev/null || true
  uci commit firewall 2>/dev/null || true
  uci commit system 2>/dev/null || true
}

disable_ipv6_runtime() {
  [ "$DISABLE_IPV6" = "1" ] || return 0

  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/91-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
net.ipv6.conf.all.accept_ra=0
net.ipv6.conf.default.accept_ra=0
EOF
  sysctl -p /etc/sysctl.d/91-disable-ipv6.conf >/dev/null 2>&1 || true

  uci -q delete network.wan6 || true
  uci -q set network.lan.delegate='0' || true
  uci -q set network.lan.ip6assign='0' || true
  uci -q delete network.lan.ip6hint || true
  uci -q delete network.lan.ip6class || true
  uci -q set dhcp.lan.ra='disabled' || true
  uci -q set dhcp.lan.dhcpv6='disabled' || true
  uci -q set dhcp.lan.ndp='disabled' || true
  uci -q set dhcp.lan.ra_management='0' || true
  uci commit network 2>/dev/null || true
  uci commit dhcp 2>/dev/null || true

  disable_service_if_present odhcpd
  flush_ipv6_runtime
}

optimize_wifi_runtime() {
  [ "$OPTIMIZE_WIFI" = "1" ] || return 0
  uci show wireless >/dev/null 2>&1 || return 0

  for section in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p"); do
    band="$(uci -q get wireless.$section.band 2>/dev/null || true)"
    hwmode="$(uci -q get wireless.$section.hwmode 2>/dev/null || true)"
    country="$(uci -q get wireless.$section.country 2>/dev/null || true)"
    [ -n "$country" ] || uci -q set wireless.$section.country='CN'
    uci -q set wireless.$section.channel='auto'
    uci -q set wireless.$section.cell_density='0'
    case "$band:$hwmode" in
      2g:*|*:11g*|*:11ng*)
        uci -q set wireless.$section.htmode='HE40'
        uci -q set wireless.$section.noscan='1'
        ;;
      5g:*|6g:*|*:11a*|*:11na*|*:11ac*)
        uci -q set wireless.$section.htmode='HE80'
        ;;
    esac
  done

  for section in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
    uci -q set wireless.$section.disassoc_low_ack='0'
    uci -q set wireless.$section.wmm='1'
  done

  uci commit wireless 2>/dev/null || true
}

set_wifi_password_runtime() {
  [ "$SET_WIFI_PASSWORD" = "1" ] || return 0
  uci show wireless >/dev/null 2>&1 || return 0

  for section in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
    mode="$(uci -q get wireless.$section.mode 2>/dev/null || true)"
    [ -n "$mode" ] || mode='ap'
    [ "$mode" = "ap" ] || continue
    uci -q set wireless.$section.disabled='0'
    uci -q set wireless.$section.encryption='psk2+ccmp'
    uci -q set wireless.$section.key="$WIFI_PASSWORD"
  done

  uci commit wireless 2>/dev/null || true
}

optimize_thermal_runtime() {
  [ "$OPTIMIZE_THERMAL" = "1" ] || return 0

  for gov_file in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov_file" ] || continue
    avail_file="${gov_file%/*}/scaling_available_governors"
    for gov in schedutil ondemand powersave; do
      if [ ! -f "$avail_file" ] || grep -qw "$gov" "$avail_file" 2>/dev/null; then
        echo "$gov" >"$gov_file" 2>/dev/null && break
      fi
    done
  done
}

lean_services_runtime() {
  [ "$LEAN_SERVICES" = "1" ] || return 0
  for svc in \
    adguardhome adbyby alist aria2 filebrowser frpc frps heimdall homeproxy mihomo mosdns \
    minidlna miniupnpd netdata nginx openclash qbittorrent sing-box smartdns sqm tailscale \
    vsftpd zerotier dockerd containerd
  do
    disable_service_if_present "$svc"
  done
}

lan_ip() {
  uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1
}

echo "[1/8] checking files"
for f in \
  files/v2raya-policy.cgi \
  files/v2raya-policy-apply \
  files/v2raya-device-policy \
  files/v2raya-dns-policy \
  files/v2raya-sync-auth \
  files/v2raya-policy-boot \
  files/v2raya-bind \
  files/v2raya-import-lines \
  files/v2raya-bind-html.lua \
  files/v2raya-devices-html.lua \
  files/v2raya-policy-build.lua \
  files/99-v2raya-device-policy \
  files/v2raya-policy.setting.json
do
  need_file "$f"
done

echo "[2/8] installing packages"
install_packages
ensure_geo_symlinks

echo "[3/8] installing local panel and policy scripts"
mkdir -p /www/cgi-bin /www-v2raya-policy/cgi-bin /usr/libexec /usr/bin /etc/hotplug.d/iface /etc/v2raya
cp files/v2raya-policy.cgi /www/cgi-bin/v2raya-policy
cp files/v2raya-policy-apply /usr/bin/v2raya-policy-apply
cp files/v2raya-device-policy /usr/bin/v2raya-device-policy
cp files/v2raya-dns-policy /usr/bin/v2raya-dns-policy
cp files/v2raya-sync-auth /usr/bin/v2raya-sync-auth
cp files/v2raya-policy-boot /etc/init.d/v2raya-policy-boot
cp files/v2raya-bind /usr/bin/v2raya-bind
cp files/v2raya-import-lines /usr/bin/v2raya-import-lines
cp files/v2raya-bind-html.lua /usr/libexec/v2raya-bind-html.lua
cp files/v2raya-devices-html.lua /usr/libexec/v2raya-devices-html.lua
cp files/v2raya-policy-build.lua /usr/libexec/v2raya-policy-build.lua
cp files/99-v2raya-device-policy /etc/hotplug.d/iface/99-v2raya-device-policy
cp files/v2raya-policy.setting.json /etc/v2raya-policy.setting.json
ln -sf /www/cgi-bin/v2raya-policy /www-v2raya-policy/cgi-bin/v2raya-policy
cat >/www-v2raya-policy/index.html <<'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=/cgi-bin/v2raya-policy"><title>v2rayA Policy</title><script>location.replace('/cgi-bin/v2raya-policy');</script></head><body>Loading v2rayA policy panel...</body></html>
EOF
cat >/www-v2raya-policy/cgi-bin/luci <<'EOF'
#!/bin/sh
uri="${REQUEST_URI%%\?*}"
[ -n "$uri" ] || uri="/cgi-bin/luci/"
if [ "$uri" = "/cgi-bin/luci" ] || [ "$uri" = "/cgi-bin/luci/" ]; then
  printf 'Status: 302 Found\r\nLocation: /cgi-bin/v2raya-policy\r\nCache-Control: no-store\r\n\r\n'
else
  printf 'Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\nNot Found\n'
fi
EOF
chmod +x /www/cgi-bin/v2raya-policy /usr/bin/v2raya-policy-apply /usr/bin/v2raya-device-policy /usr/bin/v2raya-dns-policy /usr/bin/v2raya-sync-auth /usr/bin/v2raya-bind /usr/bin/v2raya-import-lines /usr/libexec/v2raya-*.lua /etc/hotplug.d/iface/99-v2raya-device-policy /etc/init.d/v2raya-policy-boot
chmod +x /www-v2raya-policy/cgi-bin/luci

echo "[4/8] writing auth and device map"
cat >/etc/v2raya-policy.auth <<EOF
V2RAYA_API="http://127.0.0.1:2017"
V2RAYA_USER="$V2RAYA_USER"
V2RAYA_PASS="$V2RAYA_PASS"
ENABLE_DNS_POLICY="$ENABLE_DNS_POLICY"
DNS_HIJACK_PRIMARY="$DNS_HIJACK_PRIMARY"
DNS_HIJACK_SECONDARY="$DNS_HIJACK_SECONDARY"
EOF

/usr/bin/v2raya-sync-auth "$V2RAYA_USER" "$V2RAYA_PASS" "$PANEL_USER" "$PANEL_PASS" >/dev/null 2>&1 || true

if [ "$RESET_DEVICE_MAP" = "1" ]; then
  cat >/etc/v2raya-policy.map <<'EOF'
# mac ip outbound label
EOF
elif [ "$RESTORE_DEVICE_MAP" = "1" ] && [ -f snapshot-config/v2raya-policy.map ]; then
  cp snapshot-config/v2raya-policy.map /etc/v2raya-policy.map
elif [ ! -f /etc/v2raya-policy.map ]; then
  cat >/etc/v2raya-policy.map <<'EOF'
# mac ip outbound label
EOF
fi

echo "[5/8] configuring v2rayA, BBR, and 8088 entry"
uci set v2raya.config.enabled='1' 2>/dev/null || true
uci set v2raya.config.address='0.0.0.0:2017' 2>/dev/null || true
uci set v2raya.config.v2ray_bin='/usr/bin/xray' 2>/dev/null || true
uci set v2raya.config.log_level='info' 2>/dev/null || true
uci set v2raya.config.ipv6_support='off' 2>/dev/null || true
uci set v2raya.config.nftables_support='auto' 2>/dev/null || true
uci commit v2raya 2>/dev/null || true

if [ "$ENABLE_BBR" = "1" ]; then
  modprobe tcp_bbr 2>/dev/null || true
  mkdir -p /etc/modules.d /etc/sysctl.d
  qdisc="$(choose_qdisc)"
  echo tcp_bbr >/etc/modules.d/tcp-bbr
  cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=__QDISC__
net.ipv4.tcp_congestion_control=bbr
EOF
  sed -i "s/__QDISC__/$qdisc/g" /etc/sysctl.d/99-bbr.conf
  sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
fi

disable_ipv6_runtime
optimize_router_runtime
set_wifi_password_runtime
optimize_wifi_runtime
optimize_thermal_runtime
lean_services_runtime
ensure_access_services_runtime
install_frpc_runtime

if [ "$ENABLE_BOOT_START" = "1" ]; then
  /etc/init.d/v2raya-policy-boot enable >/dev/null 2>&1 || true
fi

ensure_uhttpd_8088 || {
  echo "error: 8088 local panel failed to start." >&2
  exit 1
}

if [ "$RESTORE_V2RAYA_DB" = "1" ]; then
  echo "[optional] restoring v2rayA database"
  /etc/init.d/v2raya stop >/dev/null 2>&1 || true
  [ -f optional-v2raya-db/bolt.db.base64 ] && decode_base64_file optional-v2raya-db/bolt.db.base64 /etc/v2raya/bolt.db
  [ -f optional-v2raya-db/boltv4.db.base64 ] && decode_base64_file optional-v2raya-db/boltv4.db.base64 /etc/v2raya/boltv4.db
  chmod 600 /etc/v2raya/bolt.db /etc/v2raya/boltv4.db 2>/dev/null || true
fi

ensure_v2raya_running || {
  echo "error: v2rayA failed to start automatically. See /tmp/v2raya-install-start.log" >&2
  exit 1
}
/etc/init.d/firewall restart >/dev/null 2>&1 || true
/etc/init.d/network reload >/dev/null 2>&1 || true
/sbin/wifi reload >/dev/null 2>&1 || wifi reload >/dev/null 2>&1 || true
sleep 3

if ! /etc/init.d/v2raya status >/dev/null 2>&1 || ! port_listening 2017; then
  ensure_v2raya_running || {
    echo "error: v2rayA stopped after firewall/network reload. See /tmp/v2raya-install-start.log" >&2
    exit 1
  }
fi

if ! verify_wifi_password; then
  echo "error: Wi-Fi password settings were not applied as expected." >&2
  exit 1
fi

if ! verify_ipv6_disabled; then
  echo "error: IPv6 disable settings were not fully applied." >&2
  exit 1
fi

if ! ensure_v2raya_account; then
  echo "error: v2rayA login $V2RAYA_USER / $V2RAYA_PASS is not working after install." >&2
  exit 1
fi

echo "[6/8] applying policy logic"
/usr/bin/v2raya-policy-apply >/tmp/v2raya-policy-install-apply.log 2>&1 || true
/usr/bin/v2raya-device-policy >/tmp/v2raya-policy-install-device.log 2>&1 || true
/usr/bin/v2raya-dns-policy >/tmp/v2raya-policy-install-dns.log 2>&1 || true

echo "[7/8] verifying"
echo "LAN IP: $(lan_ip)"
echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
/etc/init.d/v2raya status 2>/dev/null || true
[ "$ENABLE_88FRP" = "1" ] && /etc/init.d/frpc88 status 2>/dev/null || true

echo "[8/8] result"
echo "Local panel: http://$(lan_ip)/cgi-bin/v2raya-policy"
echo "Port entry:  http://$(lan_ip):8088/"
echo "Panel login: $PANEL_USER / $PANEL_PASS"
if [ "$SET_ROOT_PASSWORD" = "1" ]; then
  echo "Root login:  root / $ROOT_PASSWORD"
else
  echo "Root login:  unchanged"
fi
[ "$ENABLE_88FRP" = "1" ] && echo "Remote SSH:  ssh root@${FRP_SERVER_ADDR} -p ${FRP_REMOTE_PORT}"
[ "$ENABLE_88FRP" = "1" ] && [ "$FRP_LOCAL_PORT" = "8088" ] && echo "Remote panel: http://${FRP_SERVER_ADDR}:${FRP_REMOTE_PORT}"
echo "v2rayA Web: http://$(lan_ip):2017/"
echo "Device map restore: RESTORE_DEVICE_MAP=$RESTORE_DEVICE_MAP, RESET_DEVICE_MAP=$RESET_DEVICE_MAP"
echo "v2rayA DB restore: RESTORE_V2RAYA_DB=$RESTORE_V2RAYA_DB"
echo "DNS policy: ENABLE_DNS_POLICY=$ENABLE_DNS_POLICY, upstream=$DNS_HIJACK_PRIMARY,$DNS_HIJACK_SECONDARY"
echo "Root password policy: SET_ROOT_PASSWORD=$SET_ROOT_PASSWORD"
echo "Boot start: ENABLE_BOOT_START=$ENABLE_BOOT_START"
echo "Router tuning: OPTIMIZE_ROUTER=$OPTIMIZE_ROUTER, OPTIMIZE_WIFI=$OPTIMIZE_WIFI, LEAN_SERVICES=$LEAN_SERVICES, ENABLE_BBR=$ENABLE_BBR"
echo

# Keep root-password changes as the very last step so an SSH reconnect does not
# interrupt package install, service start, or policy provisioning.
set_root_password_runtime || true
echo "This installer does not change the LAN IP or netmask."
