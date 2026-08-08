#!/bin/sh
# Fix DHCP not assigning IPs when Passwall is enabled.
# Run on the router via SSH: sh /root/fix-dhcp-passwall.sh

set -e

TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/dhcp-passwall-fix-$TS"
mkdir -p "$BK"
cp -a /etc/config/dhcp /etc/config/passwall /usr/share/passwall/acl_normalize.sh "$BK"/ 2>/dev/null || true

echo "[1/5] Fixing LAN DHCP server..."
uci -q set dhcp.@dnsmasq[0].authoritative='1'
uci -q set dhcp.@dnsmasq[0].filter_aaaa='1'
uci -q set dhcp.@dnsmasq[0].port='53'
uci -q set dhcp.lan.ignore='0'
uci -q set dhcp.lan.dhcpv4='server'
uci -q set dhcp.lan.start='100'
uci -q set dhcp.lan.limit='150'
uci -q set dhcp.lan.leasetime='12h'
uci -q set dhcp.lan.force='1'
uci -q set dhcp.lan.ra='disabled'
uci -q set dhcp.lan.dhcpv6='disabled'
uci -q set dhcp.lan.ndp='disabled'

echo "[2/5] Excluding DHCP UDP 67/68 from Passwall..."
uci -q set passwall.@global_forwarding[0].udp_no_redir_ports='67,68'
for s in $(uci -q show passwall | awk -F'[.=]' '/=acl_rule/ {print $2}'); do
  uci -q set passwall.$s.udp_no_redir_ports='67,68'
done

echo "[3/5] Making the fix persistent in Passwall normalizer..."
if [ -f /usr/share/passwall/acl_normalize.sh ]; then
  sed -i "s/setv \${CONFIG}.@global_forwarding\[0\].udp_no_redir_ports disable/setv \${CONFIG}.@global_forwarding[0].udp_no_redir_ports '67,68'/g" /usr/share/passwall/acl_normalize.sh
  sed -i "s/setv \${CONFIG}.\$s.udp_no_redir_ports disable/setv \${CONFIG}.\$s.udp_no_redir_ports '67,68'/g" /usr/share/passwall/acl_normalize.sh
fi

uci -q commit dhcp
uci -q commit passwall

echo "[4/5] Restarting dnsmasq and Passwall..."
/etc/init.d/dnsmasq restart >/tmp/dnsmasq-dhcp-fix.log 2>&1 || true
/etc/init.d/passwall restart >/tmp/passwall-dhcp-fix.log 2>&1 || true
sleep 25

echo "[5/5] Verification..."
echo "Backup: $BK"
echo "--- DHCP config ---"
uci -q show dhcp | grep -E 'dhcp\.lan\.(ignore|dhcpv4|start|limit|leasetime|force)|dnsmasq\[0\]\.(authoritative|filter_aaaa|port)' || true
echo "--- Passwall DHCP bypass ---"
uci -q show passwall | grep -E '@global_forwarding\[0\]\.udp_no_redir_ports|\.udp_no_redir_ports=' || true
echo "--- DHCP listener ---"
netstat -lnup 2>/dev/null | grep -E ':67|:53|11400|15353' || true
echo "--- Current leases ---"
cat /tmp/dhcp.leases 2>/dev/null || true
echo "--- Passwall log tail ---"
tail -n 80 /tmp/log/passwall.log 2>/dev/null || true
echo "--- Firewall DHCP bypass ---"
nft list ruleset 2>/dev/null | grep -E 'udp dport \{ 67, 68 \}|udp dport (67|68)' | head -n 20 || true

echo "Done. Reconnect Wi-Fi clients to request new DHCP leases."
