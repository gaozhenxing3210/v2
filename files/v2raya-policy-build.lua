#!/usr/bin/lua
local json = require "luci.jsonc"
local map_file = "/etc/v2raya-policy.map"
local lease_file = "/tmp/dhcp.leases"
local routing_json = "/tmp/v2raya-policy.routing.json"
local routing_txt = "/tmp/v2raya-policy.routing.txt"
local allow_file = "/tmp/v2raya-policy.allow-macs"
local count_file = "/tmp/v2raya-policy.active-count"
local host_sync_file = "/tmp/v2raya-policy.hosts.tsv"

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function norm_mac(s) return trim(s):lower():gsub("[^0-9a-f:]", "") end
local function valid_mac(s) return not not norm_mac(s):match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)$") end
local function valid_ip(s) return not not trim(s):match("^%d+%.%d+%.%d+%.%d+$") end
local function valid_outbound(s) return s == "proxy" or not not trim(s):match("^dev%d%d$") end
local function readfile(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  return s
end
local function writefile(path, data)
  local f = assert(io.open(path, "w"))
  f:write(data or "")
  f:close()
end
local function shell_line(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return nil end
  local s = p:read("*l")
  p:close()
  return trim(s)
end
local function ip_to_num(ip)
  local a,b,c,d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a,b,c,d = tonumber(a),tonumber(b),tonumber(c),tonumber(d)
  if not a or a > 255 or not b or b > 255 or not c or c > 255 or not d or d > 255 then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end
local function num_to_ip(n)
  local a = math.floor(n / 16777216) % 256
  local b = math.floor(n / 65536) % 256
  local c = math.floor(n / 256) % 256
  local d = n % 256
  return string.format("%d.%d.%d.%d", a, b, c, d)
end
local function mask_to_prefix(mask)
  local n = ip_to_num(mask)
  if not n then return 24 end
  local prefix = 0
  for i = 31, 0, -1 do
    if math.floor(n / (2 ^ i)) % 2 == 1 then prefix = prefix + 1 else break end
  end
  return prefix
end
local function lan_cidr()
  local ip = shell_line("uci -q get network.lan.ipaddr") or "192.168.1.1"
  local mask = shell_line("uci -q get network.lan.netmask") or "255.255.255.0"
  local ipn = ip_to_num(ip) or ip_to_num("192.168.1.1")
  local maskn = ip_to_num(mask) or ip_to_num("255.255.255.0")
  local prefix = mask_to_prefix(mask)
  local network = math.floor(ipn / (2 ^ (32 - prefix))) * (2 ^ (32 - prefix))
  return num_to_ip(network) .. "/" .. tostring(prefix)
end

local leases = {}
for line in readfile(lease_file):gmatch("[^\n]+") do
  local exp, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
  if mac and ip then leases[norm_mac(mac)] = { ip = ip, name = name or "" } end
end

local entries, seen = {}, {}
for line in readfile(map_file):gmatch("[^\n]+") do
  line = trim((line:gsub("#.*$", "")))
  if line ~= "" then
    local mac, ip, outbound, label = line:match("^(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
    mac = norm_mac(mac)
    ip = trim(ip)
    outbound = trim(outbound)
    label = trim(label)
    if valid_mac(mac) and valid_outbound(outbound) then
      if leases[mac] and valid_ip(leases[mac].ip) then
        ip = leases[mac].ip
      elseif ip == "-" or ip == "auto" then
        ip = ""
      end
      if valid_ip(ip) and not seen[mac] then
        seen[mac] = true
        table.insert(entries, { mac = mac, ip = ip, outbound = outbound, label = label })
      end
    end
  end
end

local routing = {}
table.insert(routing, "# Managed by local v2rayA device policy panel.")
table.insert(routing, "# Device source IP -> v2rayA outbound slot.")
table.insert(routing, "default: direct")
table.insert(routing, "")
for _, e in ipairs(entries) do
  table.insert(routing, string.format("source(%s/32) -> %s", e.ip, e.outbound))
end
table.insert(routing, "")
table.insert(routing, "source(" .. lan_cidr() .. ") -> direct")
table.insert(routing, "ip(geoip:private, geoip:cn) -> direct")
table.insert(routing, "domain(geosite:cn) -> direct")
local routing_s = table.concat(routing, "\n") .. "\n"
writefile(routing_txt, routing_s)
writefile(routing_json, json.stringify({ routingA = routing_s }))

local macs = {}
local hosts = {}
for _, e in ipairs(entries) do table.insert(macs, e.mac) end
for _, e in ipairs(entries) do table.insert(hosts, string.format("%s\t%s", e.mac, e.ip)) end
writefile(allow_file, table.concat(macs, " "))
writefile(count_file, tostring(#entries))
writefile(host_sync_file, (#hosts > 0) and (table.concat(hosts, "\n") .. "\n") or "")
