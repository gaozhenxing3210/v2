#!/usr/bin/lua
local map_file = "/etc/v2raya-policy.map"
local lease_file = "/tmp/dhcp.leases"
local state_file = "/tmp/v2raya-policy-online.tsv"
local function esc(s) s=tostring(s or ""); return (s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")) end
local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end
local function norm_mac(s) return trim(s):lower():gsub("[^0-9a-f:]","") end
local function valid_mac(s) return norm_mac(s):match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)$") ~= nil end
local function ipnum(ip) local a,b,c,d=tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$"); if not a then return 0 end; return tonumber(a)*16777216+tonumber(b)*65536+tonumber(c)*256+tonumber(d) end
local function mask_prefix(mask) local n=ipnum(mask); if n==0 then return 24 end; local p=0; for i=31,0,-1 do if math.floor(n/(2^i))%2==1 then p=p+1 else break end end; return p end
local function shell_line(cmd) local p=io.popen(cmd.." 2>/dev/null"); if not p then return nil end; local s=p:read("*l"); p:close(); return trim(s) end
local lan_ip=shell_line("uci -q get network.lan.ipaddr") or "192.168.1.1"
local lan_mask=shell_line("uci -q get network.lan.netmask") or "255.255.255.0"
local lan_prefix=mask_prefix(lan_mask)
local lan_net=math.floor(ipnum(lan_ip)/(2^(32-lan_prefix)))*(2^(32-lan_prefix))
local function in_lan(ip) local n=ipnum(ip); return n~=0 and math.floor(n/(2^(32-lan_prefix)))*(2^(32-lan_prefix))==lan_net end
local function readfile(path) local f=io.open(path,"r"); if not f then return "" end; local s=f:read("*a") or ""; f:close(); return s end
local function writefile(path,text) local f=io.open(path,"w"); if f then f:write(text or ""); f:close() end end
local function phone(ob) return "&#35774;&#22791;"..tostring(ob or ""):sub(4) end
local routes={}
for line in readfile(map_file):gmatch("[^\n]+") do local mac,ip,out=line:match("^(%S+)%s+(%S+)%s+(%S+)"); if mac and valid_mac(mac) then routes[norm_mac(mac)]=out end end
local names, lease_devices = {}, {}
for line in readfile(lease_file):gmatch("[^\n]+") do
  local exp,mac,ip,name=line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
  if ip and mac and valid_mac(mac) and in_lan(ip) then mac=norm_mac(mac); if name and name~="*" then names[mac]=name end; lease_devices[mac]={ip=ip,mac=mac,name=names[mac] or name or "dhcp-device"} end
end
local devices, seen = {}, {}
local function add(ip,mac,name,source)
  if not in_lan(ip) or not valid_mac(mac) then return end
  mac=norm_mac(mac); if seen[mac] then return end; seen[mac]=true
  local lease=lease_devices[mac]
  table.insert(devices,{ip=ip,mac=mac,name=name or names[mac] or (lease and lease.name) or source or "unknown-device",source=source or "online"})
end

local online = {}
local function mark_online(ip,mac,source)
  if not in_lan(ip) or not valid_mac(mac) then return end
  mac=norm_mac(mac)
  if not online[mac] then
    online[mac] = { ip = ip, mac = mac, source = source }
  elseif source == "neigh" then
    online[mac].ip = ip
    online[mac].source = source
  end
end

for line in readfile("/proc/net/arp"):gmatch("[^\n]+") do
  local ip,hw,flags,mac,mask,dev=line:match("^(%d+%.%d+%.%d+%.%d+)%s+(%S+)%s+(%S+)%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(%S+)%s+(%S+)")
  if ip and flags=="0x2" and dev=="br-lan" and mac~="00:00:00:00:00:00" then mark_online(ip,mac,"arp") end
end
local p=io.popen("ip neigh show dev br-lan 2>/dev/null")
if p then for line in p:lines() do local ip,mac,state=line:match("^(%d+%.%d+%.%d+%.%d+)%s+.*lladdr%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(%S+)"); if ip and mac and state~="FAILED" and state~="INCOMPLETE" then mark_online(ip,mac,"neigh") end end; p:close() end

for mac, d in pairs(online) do
  local lease = lease_devices[mac]
  add(lease and lease.ip or d.ip, mac, lease and lease.name or nil, d.source)
end
table.sort(devices,function(a,b) return ipnum(a.ip)<ipnum(b.ip) end)
if #devices==0 then os.remove(state_file); print('<tr><td colspan="6" class="muted">&#24403;&#21069;&#27809;&#26377;&#25235;&#21040;&#22312;&#32447;&#20869;&#32593;&#35774;&#22791;&#12290;</td></tr>'); os.exit(0) end
local now=os.time(); local old_seen={}
for line in readfile(state_file):gmatch("[^\n]+") do local mac,ip,since=line:match("^(%S+)%s+(%S+)%s+(%d+)"); if mac and valid_mac(mac) then old_seen[norm_mac(mac)]={ip=ip,since=tonumber(since) or now} end end
local st={}; for _,d in ipairs(devices) do local old=old_seen[d.mac]; d.since=(old and old.ip==d.ip and old.since) or now; table.insert(st,string.format("%s\t%s\t%d",d.mac,d.ip,d.since)) end; writefile(state_file,table.concat(st,"\n").."\n")
for _,d in ipairs(devices) do
  local cur=routes[d.mac] or "wan"; local route=cur=="wan" and '<span class="route">&#26412;&#22320;</span>' or '<span class="route proxy">v2rayA '..esc(cur)..'</span>'
  print('<tr><td><div class="device-line"><span class="status-dot online"></span><div><div class="device">'..esc(d.name)..'</div><div class="small">'..esc(d.ip)..' / '..esc(d.source)..'</div></div></div></td>')
  print('<td>'..esc(d.mac)..'</td><td><span class="online-time" data-online-since="'..d.since..'">0&#31186;</span></td><td>'..route..'</td>')
  print('<td><form class="inline" method="post"><input type="hidden" name="action" value="route"><input type="hidden" name="mac" value="'..esc(d.mac)..'"><input type="hidden" name="ip" value="'..esc(d.ip)..'"><input type="hidden" name="label" value="'..esc(d.name)..'"><select name="outbound">')
  print('<option value="wan"'..(cur=="wan" and ' selected' or '')..'>&#26412;&#22320;</option>')
  for i=1,20 do local ob=string.format("dev%02d",i); print('<option value="'..ob..'"'..(cur==ob and ' selected' or '')..'>'..phone(ob)..'</option>') end
  print('</select><button type="submit">&#24212;&#29992;</button></form></td><td><form class="inline" method="post"><input type="hidden" name="action" value="wan"><input type="hidden" name="mac" value="'..esc(d.mac)..'"><button class="wan" type="submit">&#26412;&#22320;</button></form></td></tr>')
end
