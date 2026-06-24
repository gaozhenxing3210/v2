#!/usr/bin/lua
local socket = require "socket"

local listen_host = arg[1] or "127.0.0.1"
local listen_port = tonumber(arg[2] or "53000") or 53000
local socks_host = arg[3] or ""
local socks_port = tonumber(arg[4] or "0") or 0
local socks_user = arg[5] or ""
local socks_pass = arg[6] or ""
local doh_url = arg[7] or "https://dns.alidns.com/dns-query,https://doh.pub/dns-query"
local doh_host = arg[8] or "dns.alidns.com,doh.pub"
local doh_ip = arg[9] or ","

local function split_csv(s)
  local out = {}
  s = tostring(s or "")
  for item in s:gmatch("[^,]+") do
    item = (item:gsub("^%s+", ""):gsub("%s+$", ""))
    if item ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

local doh_urls = split_csv(doh_url)
local doh_hosts = split_csv(doh_host)
local doh_ips = split_csv(doh_ip)
if #doh_urls == 0 then
  doh_urls = { "https://dns.alidns.com/dns-query" }
end
if #doh_hosts == 0 then
  doh_hosts = { "dns.alidns.com" }
end

local function q(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data or "")
  f:close()
end

local function doh_query(packet)
  local req = os.tmpname()
  write_file(req, packet)
  for i, url in ipairs(doh_urls) do
    local host = doh_hosts[i] or doh_hosts[1] or "dns.alidns.com"
    local ip = doh_ips[i] or ""
    local resp = os.tmpname()
    local cmd = {
      "curl",
      "-fsS",
      "--connect-timeout", "8",
      "--max-time", "15",
      "--socks5-hostname", socks_host .. ":" .. tostring(socks_port),
      "-H", "accept: application/dns-message",
      "-H", "content-type: application/dns-message",
      "--data-binary", "@" .. req,
      "-o", resp,
      url,
    }
    if ip ~= "" then
      table.insert(cmd, 7, host .. ":443:" .. ip)
      table.insert(cmd, 7, "--resolve")
    end
    if socks_user ~= "" or socks_pass ~= "" then
      table.insert(cmd, 7, socks_user .. ":" .. socks_pass)
      table.insert(cmd, 7, "--proxy-user")
    end
    local shell = {}
    for _, v in ipairs(cmd) do
      shell[#shell + 1] = q(v)
    end
    local ok = os.execute(table.concat(shell, " ") .. " >/dev/null 2>&1")
    local data = read_file(resp)
    os.remove(resp)
    if ok and data and #data > 0 then
      os.remove(req)
      return data
    end
  end
  os.remove(req)
  return nil
end

local function handle_udp(udp)
  local packet, ip, port = udp:receivefrom()
  if not packet or not ip or not port then
    return
  end
  local resp = doh_query(packet)
  if resp and #resp > 0 then
    udp:sendto(resp, ip, port)
  end
end

local function handle_tcp_client(client)
  client:settimeout(10)
  local lenbuf = client:receive(2)
  if not lenbuf or #lenbuf ~= 2 then
    client:close()
    return
  end
  local len = lenbuf:byte(1) * 256 + lenbuf:byte(2)
  if len <= 0 then
    client:close()
    return
  end
  local packet = client:receive(len)
  if not packet or #packet ~= len then
    client:close()
    return
  end
  local resp = doh_query(packet)
  if resp and #resp > 0 then
    local n = #resp
    client:send(string.char(math.floor(n / 256) % 256, n % 256) .. resp)
  end
  client:close()
end

local udp = assert(socket.udp())
assert(udp:setsockname(listen_host, listen_port))
udp:settimeout(0)

local tcp = assert(socket.bind(listen_host, listen_port))
tcp:settimeout(0)

while true do
  local readable = socket.select({ udp, tcp }, nil, 1)
  for _, s in ipairs(readable) do
    if s == udp then
      handle_udp(udp)
    elseif s == tcp then
      local client = tcp:accept()
      if client then
        handle_tcp_client(client)
      end
    end
  end
end
