#!/bin/sh

set -eu

BASE_DIR="/etc/pwdev"
CONFIG_FILE="$BASE_DIR/config"
DEVICES_FILE="$BASE_DIR/devices.db"
HAPROXY_CFG="$BASE_DIR/haproxy.cfg"
SERVICE_FILE="/etc/init.d/pwdev-haproxy"

ensure_base() {
    mkdir -p "$BASE_DIR"
    [ -f "$DEVICES_FILE" ] || touch "$DEVICES_FILE"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat >"$CONFIG_FILE" <<'EOF'
PASSWALL_CONFIG='passwall'
TEMPLATE_NODE=''
BIND_ADDRESS='127.0.0.1'
PORT_START='20001'
TCP_PROXY_MODE='global'
UDP_PROXY_MODE='global'
EOF
    fi
}

load_config() {
    ensure_base
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
}

save_config_value() {
    key="$1"
    value="$2"
    tmp_file="${CONFIG_FILE}.tmp"
    awk -F= -v k="$key" -v v="$value" '
        BEGIN { updated = 0 }
        $1 == k {
            print k "='\''" v "'\''"
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print k "='\''" v "'\''"
            }
        }
    ' "$CONFIG_FILE" >"$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
}

slugify() {
    printf '%s' "$1" | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/; s/[^a-z0-9_-]/_/g'
}

find_template_node() {
    if [ -n "${TEMPLATE_NODE:-}" ] && [ "$(uci -q get "${PASSWALL_CONFIG}.${TEMPLATE_NODE}" 2>/dev/null || true)" = "nodes" ]; then
        echo "$TEMPLATE_NODE"
        return 0
    fi

    for node in $(uci show "$PASSWALL_CONFIG" | grep "=nodes" | cut -d '.' -f 2 | cut -d '=' -f 1); do
        protocol="$(uci -q get "${PASSWALL_CONFIG}.${node}.protocol" 2>/dev/null || true)"
        address="$(uci -q get "${PASSWALL_CONFIG}.${node}.address" 2>/dev/null || true)"
        case "$protocol" in
            _shunt|_balancing|_iface)
                continue
                ;;
        esac
        [ -z "$address" ] && continue
        [ "$address" = "127.0.0.1" ] && continue
        echo "$node"
        return 0
    done

    return 1
}

template_address() {
    template="$(find_template_node || true)"
    [ -n "$template" ] || return 1
    uci -q get "${PASSWALL_CONFIG}.${template}.address" 2>/dev/null
}

template_port() {
    template="$(find_template_node || true)"
    [ -n "$template" ] || return 1
    uci -q get "${PASSWALL_CONFIG}.${template}.port" 2>/dev/null
}

find_lease_ip_by_hostname() {
    hostname="$1"
    awk -v h="$hostname" '$4 == h { print $3; found = 1 } END { if (!found) exit 1 }' /tmp/dhcp.leases
}

list_online_devices() {
    if [ -s /tmp/dhcp.leases ]; then
        echo "Online DHCP leases:"
        awk '{ printf("  hostname=%s  ip=%s  mac=%s\n", $4, $3, $2) }' /tmp/dhcp.leases
    else
        echo "No DHCP leases found."
    fi
}

valid_hostname() {
    name="$1"
    [ -n "$name" ] || return 1
    [ "$name" != "*" ] || return 1
    [ "$name" != "?" ] || return 1
    [ "$name" != "-" ] || return 1
    return 0
}

next_port() {
    port="${PORT_START}"
    while grep -q "^[^|]*|[^|]*|${port}|.*$" "$DEVICES_FILE" 2>/dev/null; do
        port=$((port + 1))
    done
    echo "$port"
}

require_device_absent() {
    name="$1"
    if grep -q "^${name}|" "$DEVICES_FILE" 2>/dev/null; then
        echo "Device already exists: $name" >&2
        exit 1
    fi
}

require_device_present() {
    name="$1"
    if ! grep -q "^${name}|" "$DEVICES_FILE" 2>/dev/null; then
        echo "Device not found: $name" >&2
        exit 1
    fi
}

get_device_line() {
    grep "^$1|" "$DEVICES_FILE" | tail -n 1
}

rewrite_device_line() {
    name="$1"
    new_line="$2"
    tmp_file="${DEVICES_FILE}.tmp"
    awk -F'|' -v n="$name" -v line="$new_line" '
        BEGIN { replaced = 0 }
        $1 == n {
            if (!replaced) {
                print line
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print line
            }
        }
    ' "$DEVICES_FILE" >"$tmp_file"
    mv "$tmp_file" "$DEVICES_FILE"
}

install_service() {
    if [ -f "$SERVICE_FILE" ]; then
        chmod 755 "$SERVICE_FILE"
        return 0
    fi

    cat >"$SERVICE_FILE" <<'EOF'
#!/bin/sh /etc/rc.common

START=98
STOP=15
USE_PROCD=1

HAPROXY_BIN="/usr/sbin/haproxy"
HAPROXY_CONFIG="/etc/pwdev/haproxy.cfg"

start_service() {
    [ -s "$HAPROXY_CONFIG" ] || return 0
    procd_open_instance
    procd_set_param respawn
    procd_set_param file "$HAPROXY_CONFIG"
    procd_set_param reload_signal USR2
    procd_set_param command "$HAPROXY_BIN" -q -W -db -f "$HAPROXY_CONFIG" -p /var/run/pwdev-haproxy.pid
    procd_close_instance
}

extra_command "check" "Check pwdev haproxy config"
check() {
    [ -s "$HAPROXY_CONFIG" ] || return 0
    "$HAPROXY_BIN" -c -q -V -f "$HAPROXY_CONFIG"
}
EOF

    chmod 755 "$SERVICE_FILE"
}

generate_haproxy_cfg() {
    {
        echo "global"
        echo "    maxconn 60000"
        echo "    stats socket /var/run/pwdev-haproxy.sock mode 600 level admin expose-fd listeners"
        echo
        echo "defaults"
        echo "    mode tcp"
        echo "    timeout connect 5s"
        echo "    timeout client 1m"
        echo "    timeout server 1m"
        echo "    option dontlognull"
        echo

        if [ ! -s "$DEVICES_FILE" ]; then
            echo "listen placeholder"
            echo "    bind 127.0.0.1:65530"
            echo "    mode tcp"
            echo "    disabled"
            echo
        else
            while IFS='|' read -r name source local_port upstream_ip upstream_port tcp_mode udp_mode; do
                [ -z "$name" ] && continue
                slug="$(slugify "$name")"
                echo "listen pwdev_${slug}"
                echo "    bind ${BIND_ADDRESS}:${local_port}"
                echo "    mode tcp"
                echo "    balance roundrobin"
                echo "    server upstream ${upstream_ip}:${upstream_port} check inter 3s fall 2 rise 1"
                echo
            done <"$DEVICES_FILE"
        fi
    } >"$HAPROXY_CFG"
}

reload_haproxy_service() {
    install_service
    /etc/init.d/pwdev-haproxy enable >/dev/null 2>&1 || true
    /etc/init.d/pwdev-haproxy check
    /etc/init.d/pwdev-haproxy reload >/dev/null 2>&1 || /etc/init.d/pwdev-haproxy restart >/dev/null 2>&1
}

cleanup_pwdev_sections() {
    keep_nodes=""
    keep_acls=""
    while IFS='|' read -r name source local_port upstream_ip upstream_port tcp_mode udp_mode; do
        [ -z "$name" ] && continue
        slug="$(slugify "$name")"
        keep_nodes="${keep_nodes} pwdev_${slug}"
        keep_acls="${keep_acls} pwacl_${slug}"
    done <"$DEVICES_FILE"

    for sid in $(uci show "$PASSWALL_CONFIG" | grep "^${PASSWALL_CONFIG}\.pwdev_" | cut -d '.' -f 2 | cut -d '=' -f 1); do
        echo "$keep_nodes" | grep -qw "$sid" || uci -q delete "${PASSWALL_CONFIG}.${sid}"
    done
    for sid in $(uci show "$PASSWALL_CONFIG" | grep "^${PASSWALL_CONFIG}\.pwacl_" | cut -d '.' -f 2 | cut -d '=' -f 1); do
        echo "$keep_acls" | grep -qw "$sid" || uci -q delete "${PASSWALL_CONFIG}.${sid}"
    done
}

clone_template_to_local_node() {
    template="$1"
    node_id="$2"
    local_port="$3"
    remarks="$4"

    uci -q delete "${PASSWALL_CONFIG}.${node_id}" || true
    uci set "${PASSWALL_CONFIG}.${node_id}=nodes"

    uci show "${PASSWALL_CONFIG}.${template}" | while IFS= read -r line; do
        key="$(echo "$line" | cut -d '.' -f 3 | cut -d '=' -f 1)"
        value="$(echo "$line" | cut -d '=' -f 2-)"
        [ "$key" = "" ] && continue
        [ "$key" = ".type" ] && continue
        uci set "${PASSWALL_CONFIG}.${node_id}.${key}=${value}"
    done

    uci set "${PASSWALL_CONFIG}.${node_id}.address='127.0.0.1'"
    uci set "${PASSWALL_CONFIG}.${node_id}.port='${local_port}'"
    uci set "${PASSWALL_CONFIG}.${node_id}.remarks='${remarks}'"
    uci set "${PASSWALL_CONFIG}.${node_id}.add_from='pwdev'"
}

write_acl_rule() {
    acl_id="$1"
    source="$2"
    node_id="$3"
    name="$4"
    tcp_mode="$5"
    udp_mode="$6"

    uci -q delete "${PASSWALL_CONFIG}.${acl_id}" || true
    uci set "${PASSWALL_CONFIG}.${acl_id}=acl_rule"
    uci set "${PASSWALL_CONFIG}.${acl_id}.enabled='1'"
    uci set "${PASSWALL_CONFIG}.${acl_id}.remarks='${name}'"
    uci set "${PASSWALL_CONFIG}.${acl_id}.sources='${source}'"
    uci set "${PASSWALL_CONFIG}.${acl_id}.tcp_proxy_mode='${tcp_mode}'"
    uci set "${PASSWALL_CONFIG}.${acl_id}.udp_proxy_mode='${udp_mode}'"
    uci set "${PASSWALL_CONFIG}.${acl_id}.tcp_node='${node_id}'"
    uci set "${PASSWALL_CONFIG}.${acl_id}.udp_node='tcp'"
}

cmd_install() {
    ensure_base
    install_service
    echo "Installed:"
    echo "  script:  /usr/bin/pwdev"
    echo "  config:  $CONFIG_FILE"
    echo "  devices: $DEVICES_FILE"
    echo "  service: $SERVICE_FILE"
}

cmd_inspect() {
    load_config
    template="$(find_template_node || true)"
    if [ -z "$template" ]; then
        echo "No usable Passwall template node found." >&2
        exit 1
    fi
    save_config_value TEMPLATE_NODE "$template"
    load_config
    echo "passwall config: $PASSWALL_CONFIG"
    echo "template node:   $template"
    uci show "${PASSWALL_CONFIG}.${template}"
}

cmd_add() {
    load_config
    [ $# -ge 2 ] || {
        echo "Usage: pwdev add <device_name> <source_ip_or_mac> [upstream_proxy_ip] [upstream_port]" >&2
        exit 1
    }
    name="$1"
    source="$2"
    upstream_ip="${3:-}"
    upstream_port="${4:-}"
    [ -n "$upstream_ip" ] || upstream_ip="$(template_address || true)"
    [ -n "$upstream_port" ] || upstream_port="$(template_port || true)"
    [ -n "$upstream_ip" ] || {
        echo "Upstream proxy IP is empty and template address was not found." >&2
        exit 1
    }
    [ -n "$upstream_port" ] || upstream_port="65436"
    require_device_absent "$name"
    local_port="$(next_port)"
    echo "${name}|${source}|${local_port}|${upstream_ip}|${upstream_port}|${TCP_PROXY_MODE}|${UDP_PROXY_MODE}" >>"$DEVICES_FILE"
    echo "Added device: $name"
    echo "  source     = $source"
    echo "  local_port = $local_port"
    echo "  upstream   = ${upstream_ip}:${upstream_port}"
    echo "Run: pwdev sync restart-passwall"
}

cmd_add_host() {
    load_config
    [ $# -ge 2 ] || {
        echo "Usage: pwdev add-host <device_name> <dhcp_hostname> [upstream_proxy_ip] [upstream_port]" >&2
        exit 1
    }
    name="$1"
    hostname="$2"
    upstream_ip="${3:-}"
    upstream_port="${4:-}"
    source="$(find_lease_ip_by_hostname "$hostname" || true)"
    [ -n "$source" ] || {
        echo "DHCP hostname not found: $hostname" >&2
        echo "Run: pwdev online" >&2
        exit 1
    }
    cmd_add "$name" "$source" "${upstream_ip:-}" "${upstream_port:-}"
}

cmd_add_online_all() {
    load_config
    prefix="${1:-PC}"
    upstream_ip="${2:-}"
    upstream_port="${3:-}"
    count=0

    [ -s /tmp/dhcp.leases ] || {
        echo "No DHCP leases found." >&2
        exit 1
    }

    while read -r lease_line; do
        hostname="$(echo "$lease_line" | awk '{print $4}')"
        ipaddr="$(echo "$lease_line" | awk '{print $3}')"
        [ -n "$hostname" ] || continue
        valid_hostname "$hostname" || continue

        host_slug="$(slugify "$hostname")"
        [ -n "$host_slug" ] || host_slug="host_${count}"
        device_name="${prefix}_${host_slug}"
        if grep -q "^${device_name}|" "$DEVICES_FILE" 2>/dev/null; then
            echo "Skip existing device: $device_name"
            continue
        fi

        if [ -n "$upstream_ip" ]; then
            cmd_add "$device_name" "$ipaddr" "$upstream_ip" "${upstream_port:-}"
        else
            cmd_add "$device_name" "$ipaddr"
        fi
        count=$((count + 1))
    done </tmp/dhcp.leases

    echo "Imported online devices: $count"
    echo "Run: pwdev sync restart-passwall"
}

cmd_apply_online_all() {
    prefix="${1:-PC}"
    upstream_ip="${2:-}"
    upstream_port="${3:-}"
    cmd_add_online_all "$prefix" "${upstream_ip:-}" "${upstream_port:-}"
    cmd_sync restart-passwall
}

cmd_list() {
    load_config
    if [ ! -s "$DEVICES_FILE" ]; then
        echo "No devices."
        exit 0
    fi
    while IFS='|' read -r name source local_port upstream_ip upstream_port tcp_mode udp_mode; do
        [ -z "$name" ] && continue
        echo "$name  source=$source  local_port=$local_port  upstream=${upstream_ip}:${upstream_port}"
    done <"$DEVICES_FILE"
}

cmd_remove() {
    load_config
    [ $# -eq 1 ] || {
        echo "Usage: pwdev remove <device_name>" >&2
        exit 1
    }
    name="$1"
    require_device_present "$name"
    tmp_file="${DEVICES_FILE}.tmp"
    awk -F'|' -v n="$name" '$1 != n { print }' "$DEVICES_FILE" >"$tmp_file"
    mv "$tmp_file" "$DEVICES_FILE"
    echo "Removed device: $name"
    echo "Run: pwdev sync restart-passwall if it had already been applied before."
}

cmd_switch() {
    load_config
    [ $# -ge 2 ] || {
        echo "Usage: pwdev switch <device_name> <new_upstream_proxy_ip> [new_upstream_port]" >&2
        exit 1
    }
    name="$1"
    new_ip="$2"
    new_port="${3:-}"
    require_device_present "$name"
    old_line="$(get_device_line "$name")"
    old_source="$(echo "$old_line" | cut -d '|' -f 2)"
    old_local_port="$(echo "$old_line" | cut -d '|' -f 3)"
    old_port="$(echo "$old_line" | cut -d '|' -f 5)"
    tcp_mode="$(echo "$old_line" | cut -d '|' -f 6)"
    udp_mode="$(echo "$old_line" | cut -d '|' -f 7)"
    [ -n "$new_port" ] || new_port="$old_port"
    rewrite_device_line "$name" "${name}|${old_source}|${old_local_port}|${new_ip}|${new_port}|${tcp_mode}|${udp_mode}"
    generate_haproxy_cfg
    reload_haproxy_service
    echo "Switched $name to ${new_ip}:${new_port}"
    echo "Passwall was not restarted."
}

cmd_sync() {
    load_config
    template="$(find_template_node || true)"
    if [ -z "$template" ]; then
        echo "No usable Passwall template node found." >&2
        exit 1
    fi
    save_config_value TEMPLATE_NODE "$template"
    load_config

    cleanup_pwdev_sections

    while IFS='|' read -r name source local_port upstream_ip upstream_port tcp_mode udp_mode; do
        [ -z "$name" ] && continue
        slug="$(slugify "$name")"
        node_id="pwdev_${slug}"
        acl_id="pwacl_${slug}"
        clone_template_to_local_node "$template" "$node_id" "$local_port" "PWDEV ${name}"
        write_acl_rule "$acl_id" "$source" "$node_id" "$name" "$tcp_mode" "$udp_mode"
    done <"$DEVICES_FILE"

    uci set "${PASSWALL_CONFIG}.@global[0].acl_enable='1'"
    uci commit "$PASSWALL_CONFIG"

    generate_haproxy_cfg
    reload_haproxy_service

    if [ "${1:-}" = "restart-passwall" ]; then
        /etc/init.d/"$PASSWALL_CONFIG" restart
        echo "Passwall restarted once for initial apply."
    else
        echo "Passwall config committed."
        echo "If this is your first time applying ACL/device mapping, run:"
        echo "  pwdev sync restart-passwall"
    fi
}

cmd_set_template() {
    load_config
    [ $# -eq 1 ] || {
        echo "Usage: pwdev set-template <passwall_node_id>" >&2
        exit 1
    }
    node="$1"
    [ "$(uci -q get "${PASSWALL_CONFIG}.${node}" 2>/dev/null || true)" = "nodes" ] || {
        echo "Node not found in ${PASSWALL_CONFIG}: $node" >&2
        exit 1
    }
    save_config_value TEMPLATE_NODE "$node"
    echo "Template node set to: $node"
}

main() {
    ensure_base

    cmd="${1:-}"
    shift || true

    case "$cmd" in
        install)
            cmd_install
            ;;
        inspect)
            cmd_inspect "$@"
            ;;
        add)
            cmd_add "$@"
            ;;
        add-host)
            cmd_add_host "$@"
            ;;
        add-online-all)
            cmd_add_online_all "$@"
            ;;
        apply-online-all)
            cmd_apply_online_all "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        remove)
            cmd_remove "$@"
            ;;
        online)
            list_online_devices
            ;;
        switch)
            cmd_switch "$@"
            ;;
        sync)
            cmd_sync "$@"
            ;;
        set-template)
            cmd_set_template "$@"
            ;;
        *)
            cat <<'EOF'
Usage:
  pwdev install
  pwdev inspect
  pwdev add <device_name> <source_ip_or_mac> [upstream_proxy_ip] [upstream_port]
  pwdev add-host <device_name> <dhcp_hostname> [upstream_proxy_ip] [upstream_port]
  pwdev add-online-all [name_prefix] [upstream_proxy_ip] [upstream_port]
  pwdev apply-online-all [name_prefix] [upstream_proxy_ip] [upstream_port]
  pwdev list
  pwdev remove <device_name>
  pwdev online
  pwdev sync [restart-passwall]
  pwdev switch <device_name> <new_upstream_proxy_ip> [new_upstream_port]
  pwdev set-template <passwall_node_id>
EOF
            exit 1
            ;;
    esac
}

main "$@"
