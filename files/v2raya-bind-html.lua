#!/usr/bin/lua
local json = require "luci.jsonc"
local path = arg[1]
local map_path = arg[2] or "/etc/v2raya-policy.map"

local function esc(s)
  s = tostring(s or "")
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function phone(ob)
  return "&#35774;&#22791;" .. tostring(ob or ""):sub(4)
end

local function readfile(p)
  local f = io.open(p, "r")
  if not f then
    return ""
  end
  local s = f:read("*a") or ""
  f:close()
  return s
end

local obj = json.parse(readfile(path)) or {}
local touch = obj.data and obj.data.touch or {}
local servers, placeholders = {}, {}
local real_server_idx = 0

for _, s in ipairs(touch.servers or {}) do
  local key = "server|" .. tostring(s.id) .. "|0"
  if tostring(s.address or ""):match("^1%.1%.1%.1") then
    placeholders[key] = s
  else
    real_server_idx = real_server_idx + 1
    table.insert(servers, {
      value = key,
      key = key,
      id = "ID" .. real_server_idx,
      name = s.name or "",
      address = s.address or "",
      net = s.net or "",
      label = "ID" .. real_server_idx .. " - " .. (s.name or "") .. " - " .. (s.address or "")
    })
  end
end

for sub_idx, sub in ipairs(touch.subscriptions or {}) do
  local sub_no = sub_idx - 1
  for _, s in ipairs(sub.servers or {}) do
    local key = "subscriptionServer|" .. s.id .. "|" .. sub_no
    table.insert(servers, {
      value = key,
      key = key,
      id = "SUB" .. sub_no .. "/ID" .. s.id,
      name = s.name or "",
      address = s.address or "",
      net = s.net or "",
      label = "SUB" .. sub_no .. " ID" .. s.id .. " - " .. (s.name or "") .. " - " .. (s.address or "")
    })
  end
end

local online_ips = {}
local p = io.popen("ip neigh show dev br-lan 2>/dev/null")
if p then
  for line in p:lines() do
    local ip = line:match("^(%d+%.%d+%.%d+%.%d+)%s+")
    if ip and line:match("%slladdr%s") and not line:match("%sFAILED%s*$") and not line:match("%sINCOMPLETE%s*$") then
      online_ips[ip] = true
    end
  end
  p:close()
end

local arp = io.popen("cat /proc/net/arp 2>/dev/null")
if arp then
  for line in arp:lines() do
    local ip, hw, flags, mac, dev = line:match("^(%d+%.%d+%.%d+%.%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+%S+%s+(%S+)")
    if ip and flags == "0x2" and dev == "br-lan" and mac ~= "00:00:00:00:00:00" then
      online_ips[ip] = true
    end
  end
  arp:close()
end

local dev_ips = {}
for line in readfile(map_path):gmatch("[^\n]+") do
  line = (line:gsub("#.*$", "")):gsub("^%s+", ""):gsub("%s+$", "")
  local mac, ip, out = line:match("^(%S+)%s+(%S+)%s+(%S+)")
  if ip and out and out:match("^dev%d%d$") and online_ips[ip] then
    dev_ips[out] = dev_ips[out] or {}
    table.insert(dev_ips[out], ip)
  end
end

local connected = {}
for _, c in ipairs(touch.connectedServer or {}) do
  connected[c.outbound or ""] = c
end

local bind_ok = os.getenv("BIND_OK") or ""
local placeholder_id = "-"
local placeholder_desc = "&#34394;&#25311;&#21344;&#20301;&#33410;&#28857;"

print('<form method="post" id="deleteNodesForm" class="node-delete-box"><input type="hidden" name="action" value="delete_nodes"><input type="hidden" name="delete_refs" id="deleteRefs"><div class="node-delete-title">&#21024;&#38500;&#20195;&#29702; IP &#33410;&#28857;</div><div class="node-delete-list">')
if #servers == 0 then
  print('<div class="muted">&#27809;&#26377;&#21487;&#21024;&#38500;&#30340;&#20195;&#29702; IP &#33410;&#28857;&#65292;&#35774;&#22791;&#23558;&#20445;&#25345; 1.1.1.1 &#34394;&#25311;&#21344;&#20301;&#12290;</div>')
else
  for _, s in ipairs(servers) do
    print('<label class="node-delete-item"><input type="checkbox" name="delete_ref" class="delete-node-check" value="' .. esc(s.value) .. '"><span>' .. esc(s.label) .. '</span></label>')
  end
end
print('</div><button class="delete-node" type="submit"' .. (#servers == 0 and ' disabled' or '') .. '>&#21024;&#38500;&#36873;&#20013;&#33410;&#28857;</button></form>')

print('<table class="dev-table"><thead><tr><th>&#35774;&#22791;</th><th>&#32465;&#23450;&#20869;&#32593; IP</th><th>&#24403;&#21069; ID</th><th>&#24403;&#21069;&#33410;&#28857;</th><th>&#32465;&#23450;&#21040; ID</th><th></th></tr></thead><tbody>')

for i = 1, 20 do
  local ob = string.format("dev%02d", i)
  local ips = dev_ips[ob]
  local has_ips = ips and #ips > 0
  local ip_cell = has_ips and esc(table.concat(ips, ", ")) or '<span class="muted">1.1.1.1</span>'
  local cur = connected[ob]
  local cur_key = cur and ((cur._type or "server") .. "|" .. cur.id .. "|" .. (cur.sub or 0)) or ""
  local show_placeholder = not has_ips
  local cur_id = placeholder_id
  local cur_node = '<div class="node-name">1.1.1.1</div><div class="small">' .. placeholder_desc .. '</div>'

  if not show_placeholder then
    cur_id = "-"
    cur_node = '<div class="node-name">1.1.1.1</div><div class="small">&#34394;&#25311;&#21344;&#20301;&#33410;&#28857;</div>'
    if placeholders[cur_key] then
      cur_id = "-"
      cur_node = '<div class="node-name">1.1.1.1</div><div class="small">&#34394;&#25311;&#21344;&#20301;&#33410;&#28857;</div>'
    end
    for _, s in ipairs(servers) do
      if s.key == cur_key then
        cur_id = esc(s.id)
        cur_node = '<div class="node-name">' .. esc(s.name) .. '</div><div class="small">' .. esc(s.address) .. ' / ' .. esc(s.net) .. '</div>'
        break
      end
    end
  end

  print('<tr><td><span class="dev-badge">' .. phone(ob) .. '</span></td><td>' .. ip_cell .. '</td><td><span class="id-badge">' .. cur_id .. '</span></td><td>' .. cur_node .. '</td><td><form class="inline bind-form" method="post"><input type="hidden" name="outbound" value="' .. ob .. '"><select name="server_ref">')
  if show_placeholder or not cur or placeholders[cur_key] then
    print('<option value="virtual|0|0" selected>1.1.1.1 - &#34394;&#25311;&#21344;&#20301;&#33410;&#28857;</option>')
  end
  for _, s in ipairs(servers) do
    local selected = (not show_placeholder and s.key == cur_key) and ' selected' or ''
    print('<option value="' .. esc(s.value) .. '"' .. selected .. '>' .. esc(s.label) .. '</option>')
  end
  local ok = (bind_ok == ob) and '<span class="bind-ok">&#32465;&#23450;&#25104;&#21151;</span>' or ''
  print('</select></td><td><button type="submit" name="action" value="bindout">&#32465;&#23450;</button>' .. ok .. '</form></td></tr>')
end

print('</tbody></table>')
