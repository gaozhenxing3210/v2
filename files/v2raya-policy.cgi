#!/bin/sh
MAP="/etc/v2raya-policy.map"
LEASES="/tmp/dhcp.leases"
APPLY="/usr/bin/v2raya-policy-apply"
AUTH="/etc/v2raya-policy.auth"
[ -f "$AUTH" ] && . "$AUTH"
: "${V2RAYA_API:=http://127.0.0.1:2017}"
: "${V2RAYA_USER:=admin}"
: "${V2RAYA_PASS:=weifeng}"
html_escape(){ sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
url_decode(){ local data="${1//+/ }"; printf '%b' "$(echo "$data" | sed 's/%/\\x/g')"; }
get_param(){ local key="$1" qs="$2" pair name val; OLDIFS="$IFS"; IFS='&'; for pair in $qs; do name="${pair%%=*}"; val="${pair#*=}"; [ "$name" = "$key" ] && { url_decode "$val"; IFS="$OLDIFS"; return; }; done; IFS="$OLDIFS"; }
get_params_csv(){ local key="$1" qs="$2" pair name val out=""; OLDIFS="$IFS"; IFS='&'; for pair in $qs; do name="${pair%%=*}"; val="${pair#*=}"; if [ "$name" = "$key" ]; then val="$(url_decode "$val")"; [ -n "$out" ] && out="$out,$val" || out="$val"; fi; done; IFS="$OLDIFS"; printf '%s' "$out"; }
normalize_mac(){ echo "$1" | tr 'A-F' 'a-f' | sed 's/[^0-9a-f:]//g'; }
valid_mac(){ echo "$1" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
valid_ip(){ echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
valid_outbound(){ echo "$1" | grep -Eq '^(proxy|dev[0-9][0-9])$'; }
map_outbound(){ awk -v m="$1" '!/^#/ && tolower($1)==m {print $3; exit}' "$MAP" 2>/dev/null; }
remove_map(){ local mac="$1"; tmp="$MAP.$$"; awk -v m="$mac" 'BEGIN{IGNORECASE=1} /^#/ || NF<3 || tolower($1)!=m {print}' "$MAP" 2>/dev/null > "$tmp"; mv "$tmp" "$MAP"; }
upsert_map(){ local mac="$1" ip="$2" outbound="$3" label="$4"; mkdir -p /etc; touch "$MAP"; remove_map "$mac"; printf '%s %s %s %s\n' "$mac" "$ip" "$outbound" "$label" >> "$MAP"; }
api_login(){
  tmp_login="/tmp/v2raya-login.$$"
  lua - "$V2RAYA_USER" "$V2RAYA_PASS" > "$tmp_login" <<'LUA'
local json = require "luci.jsonc"
print(json.stringify({ username = arg[1] or "", password = arg[2] or "" }))
LUA
  login_json="$(curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @"$tmp_login" "$V2RAYA_API/api/login" 2>/dev/null || true)"
  rm -f "$tmp_login"
  printf '%s' "$login_json" | jsonfilter -q -e '@.data.token' 2>/dev/null || true
}
api_create_outbound(){
  local token="$1" outbound="$2" tmp_outbound
  [ -n "$token" ] || return 1
  [ -n "$outbound" ] || return 1
  tmp_outbound="/tmp/v2raya-outbound.$$"
  lua - "$outbound" > "$tmp_outbound" <<'LUA'
local json = require "luci.jsonc"
print(json.stringify({ outbound = arg[1] or "" }))
LUA
  curl -fsS -m 15 -H "Content-Type: application/json" -H "Authorization: $token" --data-binary @"$tmp_outbound" "$V2RAYA_API/api/outbound" >/dev/null 2>&1 || true
  rm -f "$tmp_outbound"
}
proxy_ref_from_touch(){ lua - "$1" <<'LUA'
local json = require "luci.jsonc"
local f = io.open(arg[1], "r")
local obj = json.parse(f and f:read("*a") or "{}") or {}
if f then f:close() end
local touch = obj.data and obj.data.touch or {}
for _, c in ipairs(touch.connectedServer or {}) do
  if tostring(c.outbound or "") == "proxy" then
    print(table.concat({ tostring(c._type or "server"), tostring(c.id or ""), tostring(c.sub or 0) }, "|"))
    return
  end
end
LUA
}
proxy_is_placeholder(){
  lua - "$1" <<'LUA'
local json = require "luci.jsonc"
local f = io.open(arg[1], "r")
local obj = json.parse(f and f:read("*a") or "{}") or {}
if f then f:close() end
local touch = obj.data and obj.data.touch or {}
local proxy_id, proxy_type, proxy_sub
for _, c in ipairs(touch.connectedServer or {}) do
  if tostring(c.outbound or "") == "proxy" then
    proxy_id = tostring(c.id or "")
    proxy_type = tostring(c._type or "server")
    proxy_sub = tostring(c.sub or 0)
    break
  end
end
if proxy_id == nil then
  return
end
for _, s in ipairs(touch.servers or {}) do
  if tostring(s.id or "") == proxy_id and proxy_type == "server" and proxy_sub == "0" then
    if tostring(s.address or ""):match("^1%.1%.1%.1") then
      print("1")
    end
    return
  end
end
LUA
}
touch_running_state(){
  jsonfilter -q -i "$1" -e '@.data.running' 2>/dev/null || true
}
bootstrap_bind_runtime(){
  local outbound="$1" typ="$2" id="$3" sub="$4" token2 tmp_touch proxy_ref proxy_placeholder running
  token2="$(api_login)"
  [ -n "$token2" ] || return 1
  api_create_outbound "$token2" "proxy"
  [ "$outbound" = "proxy" ] || api_create_outbound "$token2" "$outbound"
  tmp_touch="/tmp/v2raya-bind-touch.$$"
  curl -fsS -m 10 -H "Authorization: $token2" "$V2RAYA_API/api/touch" > "$tmp_touch" 2>/dev/null || echo '{}' > "$tmp_touch"
  proxy_ref="$(proxy_ref_from_touch "$tmp_touch" || true)"
  proxy_placeholder="$(proxy_is_placeholder "$tmp_touch" || true)"
  if { [ -z "$proxy_ref" ] || [ "$proxy_placeholder" = "1" ]; } && [ -n "$id" ] && [ -n "$typ" ]; then
    /usr/bin/v2raya-bind proxy "$id" "$typ" "$sub" >/dev/null 2>&1 || true
  fi
  rm -f "$tmp_touch"
}
start_runtime_if_possible(){
  local token2="$1" tmp_touch running
  [ -n "$token2" ] || return 1
  tmp_touch="/tmp/v2raya-runtime-touch.$$"
  curl -fsS -m 10 -H "Authorization: $token2" "$V2RAYA_API/api/touch" > "$tmp_touch" 2>/dev/null || echo '{}' > "$tmp_touch"
  running="$(touch_running_state "$tmp_touch")"
  rm -f "$tmp_touch"
  [ "$running" = "true" ] && return 0
  curl -fsS -m 20 -X POST -H "Authorization: $token2" "$V2RAYA_API/api/v2ray" >/tmp/v2raya-runtime-start.log 2>&1 || true
}
json_payload_from_file(){ lua - "$1" <<'LUA'
local json = require "luci.jsonc"
local path = arg[1]
local f = io.open(path, "r")
local s = f and f:read("*a") or ""
if f then f:close() end
print(json.stringify({ url = s }))
LUA
}
delete_touch_payload(){ lua - "$1" "$2" "$3" <<'LUA'
local json = require "luci.jsonc"
print(json.stringify({ touches = { { id = tonumber(arg[2]) or 0, _type = arg[1] or "server", sub = tonumber(arg[3]) or 0 } } }))
LUA
}
delete_touches_payload(){ lua - "$1" <<'LUA'
local json = require "luci.jsonc"
local touches = {}
for ref in tostring(arg[1] or ""):gmatch("[^,]+") do
  local typ, id = ref:match("^([^|]+)|(%d+)|")
  if typ and id and (typ == "server" or typ == "subscriptionServer") then
    table.insert(touches, { id = tonumber(id), _type = typ })
  end
end
print(json.stringify({ touches = touches }))
LUA
}
find_placeholder_ref(){ lua - "$1" <<'LUA'
local json = require "luci.jsonc"
local f = io.open(arg[1], "r")
local obj = json.parse(f and f:read("*a") or "{}") or {}
if f then f:close() end
local touch = obj.data and obj.data.touch or {}
for _, s in ipairs(touch.servers or {}) do
  if tostring(s.address or ""):match("^1%.1%.1%.1") then
    print("server|" .. tostring(s.id) .. "|0")
    return
  end
end
LUA
}
find_sole_placeholder_id(){ lua - "$1" <<'LUA'
local json = require "luci.jsonc"
local f = io.open(arg[1], "r")
local obj = json.parse(f and f:read("*a") or "{}") or {}
if f then f:close() end
local touch = obj.data and obj.data.touch or {}
if #(touch.subscriptions or {}) > 0 then return end
local servers = touch.servers or {}
if #servers ~= 1 then return end
local s = servers[1]
if tostring(s.address or ""):match("^1%.1%.1%.1") then
  print(tostring(s.id or ""))
end
LUA
}
outbound_in_use_by_others(){
  local mac="$1" outbound="$2"
  awk -v m="$mac" -v o="$outbound" 'BEGIN{IGNORECASE=1} !/^#/ && NF>=3 && tolower($1)!=tolower(m) && $3==o { found=1; exit } END{ exit(found?0:1) }' "$MAP" 2>/dev/null
}
ensure_placeholder_ref(){
  local touch_file="$1" token="$2" placeholder_ref tmp_ph_link tmp_ph_payload
  placeholder_ref="$(find_placeholder_ref "$touch_file")"
  if [ -n "$placeholder_ref" ]; then
    printf '%s' "$placeholder_ref"
    return 0
  fi
  tmp_ph_link="/tmp/v2raya-placeholder-link.$$"
  tmp_ph_payload="/tmp/v2raya-placeholder-payload.$$"
  printf 'socks5://1.1.1.1:1#VIRTUAL-PLACEHOLDER' > "$tmp_ph_link"
  json_payload_from_file "$tmp_ph_link" > "$tmp_ph_payload"
  curl -fsS -m 30 -H "Content-Type: application/json" -H "Authorization: $token" --data-binary @"$tmp_ph_payload" "$V2RAYA_API/api/import" >/dev/null 2>&1 || true
  rm -f "$tmp_ph_link" "$tmp_ph_payload"
  curl -fsS -m 10 -H "Authorization: $token" "$V2RAYA_API/api/touch" > "$touch_file" 2>/dev/null || echo '{}' > "$touch_file"
  find_placeholder_ref "$touch_file"
}
prepare_real_id_slot(){
  local token2="$1" tmp_touch phid tmp_delete
  tmp_touch="/tmp/v2raya-prepare-real-touch.$$"
  curl -fsS -m 10 -H "Authorization: $token2" "$V2RAYA_API/api/touch" > "$tmp_touch" 2>/dev/null || echo '{}' > "$tmp_touch"
  phid="$(find_sole_placeholder_id "$tmp_touch" || true)"
  if [ -n "$phid" ]; then
    tmp_delete="/tmp/v2raya-prepare-real-delete.$$"
    delete_touch_payload server "$phid" 0 > "$tmp_delete"
    curl -fsS -m 30 -X DELETE -H "Content-Type: application/json" -H "Authorization: $token2" --data-binary @"$tmp_delete" "$V2RAYA_API/api/touch" >/dev/null 2>&1 || true
    rm -f "$tmp_delete"
    sleep 1
  fi
  rm -f "$tmp_touch"
}
restore_outbound_to_placeholder(){
  local outbound="$1" token2 tmp_touch placeholder_ref ph_typ ph_id ph_sub
  echo "$outbound" | grep -Eq '^dev[0-9][0-9]$' || return 1
  token2="$(api_login)"
  [ -n "$token2" ] || return 1
  tmp_touch="/tmp/v2raya-placeholder-touch.$$"
  curl -fsS -m 10 -H "Authorization: $token2" "$V2RAYA_API/api/touch" > "$tmp_touch" 2>/dev/null || echo '{}' > "$tmp_touch"
  placeholder_ref="$(ensure_placeholder_ref "$tmp_touch" "$token2")"
  rm -f "$tmp_touch"
  [ -n "$placeholder_ref" ] || return 1
  ph_typ="$(echo "$placeholder_ref" | cut -d'|' -f1)"
  ph_id="$(echo "$placeholder_ref" | cut -d'|' -f2)"
  ph_sub="$(echo "$placeholder_ref" | cut -d'|' -f3)"
  /usr/bin/v2raya-bind "$outbound" "$ph_id" "$ph_typ" "$ph_sub" >/dev/null 2>&1
}
plan_delete_nodes(){ lua - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'LUA'
local json = require "luci.jsonc"
local refs, touch_path, payload_path, rebind_path = arg[1] or "", arg[2], arg[3], arg[4]
local fallback = nil
if (arg[5] or "") ~= "" and tonumber(arg[6] or "") then
  fallback = { _type = arg[5], id = tonumber(arg[6]), sub = tonumber(arg[7] or 0) or 0 }
end
local del, touches = {}, {}
for ref in refs:gmatch("[^,]+") do
  local typ, id = ref:match("^([^|]+)|(%d+)|")
  if typ and id and (typ == "server" or typ == "subscriptionServer") then
    local key = typ .. "|" .. id
    if not del[key] then
      del[key] = true
      table.insert(touches, { id = tonumber(id), _type = typ })
    end
  end
end
local f = io.open(touch_path, "r")
local obj = json.parse(f and f:read("*a") or "{}") or {}
if f then f:close() end
local touch = obj.data and obj.data.touch or {}
local pf = assert(io.open(payload_path, "w"))
pf:write(json.stringify({ touches = touches }))
pf:close()
local rf = assert(io.open(rebind_path, "w"))
for _, c in ipairs(touch.connectedServer or {}) do
  local key = tostring(c._type or "server") .. "|" .. tostring(c.id)
  if del[key] then
    if not fallback then
      rf:write("NO_FALLBACK\n")
    else
      rf:write(table.concat({ c.outbound or "", tostring(fallback._type), tostring(fallback.id), tostring(fallback.sub or 0) }, "\t") .. "\n")
    end
  end
end
rf:close()
LUA
}
build_node_link(){ lua - "$@" <<'LUA'
local proto,name,addr,port,uuid,password,method,tls=arg[1],arg[2],arg[3],arg[4],arg[5],arg[6],arg[7],arg[8]
local json=require "luci.jsonc"
local function enc(s) s=tostring(s or ""); return (s:gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", string.byte(c)) end)) end
local function b64(s) local tmp=os.tmpname(); local f=assert(io.open(tmp,"w")); f:write(s or ""); f:close(); local p=io.popen("base64 "..tmp.." 2>/dev/null"); local out=p and p:read("*a") or ""; if p then p:close() end; os.remove(tmp); return (out:gsub("%s+","")) end
proto=tostring(proto or "vless"):lower(); name=name~="" and name or addr; local sec=tls=="tls" and "tls" or "none"
if proto=="vless" then print("vless://"..enc(uuid).."@"..addr..":"..port.."?encryption=none&type=tcp&security="..sec.."#"..enc(name))
elseif proto=="trojan" then print("trojan://"..enc(password).."@"..addr..":"..port.."?type=tcp&security="..sec.."#"..enc(name))
elseif proto=="ss" then print("ss://"..b64((method~="" and method or "aes-128-gcm")..":"..password).."@"..addr..":"..port.."#"..enc(name))
elseif proto=="vmess" then local obj={v="2",ps=name,add=addr,port=port,id=uuid,aid="0",scy="auto",net="tcp",type="none",host="",path="",tls=(tls=="tls" and "tls" or "")}; print("vmess://"..b64(json.stringify(obj)))
elseif proto=="socks5" then local userpass=""; if uuid~="" and password~="" then userpass=enc(uuid)..":"..enc(password).."@" end; print("socks5://"..userpass..addr..":"..port.."#"..enc(name))
else os.exit(2) end
LUA
}
message=""
WEB_USER="admin"
WEB_PASS="weifeng"
WEB_COOKIE_NAME="v2pol_auth"
WEB_COOKIE_VALUE="ok"
login_page(){
  printf 'Content-Type: text/html; charset=utf-8
Cache-Control: no-store

'
  cat <<'LOGINHTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>v2rayA 本地面板登录</title><style>*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f8fb;color:#142033;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",Arial,sans-serif;font-size:17px}.box{width:min(460px,calc(100vw - 32px));background:#fff;border:1px solid #dfe6ef;border-radius:8px;box-shadow:0 14px 34px rgba(20,32,51,.1);padding:28px}.mark{width:46px;height:46px;border-radius:8px;background:#1f6feb;color:#fff;display:grid;place-items:center;font-weight:800;margin-bottom:16px}.title{font-size:24px;font-weight:760;margin-bottom:8px}.sub{font-size:15px;color:#637083;margin-bottom:22px}.field{margin-bottom:16px}.field label{display:block;font-size:15px;color:#637083;margin-bottom:7px}input{width:100%;border:1px solid #dfe6ef;border-radius:7px;padding:13px 14px;font-size:17px;outline:none}input:focus{border-color:#2167d8;box-shadow:0 0 0 3px rgba(33,103,216,.12)}button{width:100%;border:0;border-radius:7px;background:#2167d8;color:white;font-size:17px;font-weight:760;padding:13px 14px;cursor:pointer}.err{margin-bottom:14px;border:1px solid #ffd6d6;background:#fff3f3;color:#b42318;border-radius:7px;padding:11px 13px;font-size:15px}.foot{margin-top:16px;color:#637083;font-size:13px;text-align:center}</style></head><body><form class="box" method="post"><input type="hidden" name="action" value="login"><div class="mark">V</div><div class="title">本地分流面板</div><div class="sub">请输入账号密码进入管理页面</div>
LOGINHTML
  [ -n "$1" ] && printf '<div class="err">%s</div>' "$1"
  cat <<'LOGINHTML'
<div class="field"><label>账号</label><input name="username" autocomplete="username" autofocus></div><div class="field"><label>密码</label><input name="password" type="password" autocomplete="current-password"></div><button type="submit">登录</button><div class="foot">v2rayA Policy Panel</div></form></body></html>
LOGINHTML
  exit 0
}
login_success(){ printf 'Status: 302 Found
Set-Cookie: %s=%s; Path=/cgi-bin/v2raya-policy; HttpOnly; SameSite=Strict
Location: /cgi-bin/v2raya-policy
Cache-Control: no-store

' "$WEB_COOKIE_NAME" "$WEB_COOKIE_VALUE"; exit 0; }
is_login_cookie(){ printf '%s' "$HTTP_COOKIE" | grep -Eq '(^|;[[:space:]]*)v2pol_auth=ok(;|$)'; }
if ! is_login_cookie; then
  if [ "$REQUEST_METHOD" = "POST" ]; then
    AUTH_LEN="$CONTENT_LENGTH"; [ -n "$AUTH_LEN" ] || AUTH_LEN=0
    read -r -n "$AUTH_LEN" BODY
    action="$(get_param action "$BODY")"
    if [ "$action" = "login" ]; then
      username="$(get_param username "$BODY")"; password="$(get_param password "$BODY")"
      [ "$username" = "$WEB_USER" ] && [ "$password" = "$WEB_PASS" ] && login_success
      login_page "&#36134;&#21495;&#25110;&#23494;&#30721;&#19981;&#23545;"
    fi
  fi
  login_page ""
fi
FLASH="/tmp/v2raya-policy.flash"
BIND_FLASH="/tmp/v2raya-policy.bindok"
if [ "${REQUEST_METHOD:-GET}" != "POST" ] && [ -f "$FLASH" ]; then
  message="$(cat "$FLASH")"
  rm -f "$FLASH"
fi
if [ "${REQUEST_METHOD:-GET}" != "POST" ] && [ -f "$BIND_FLASH" ]; then
  BIND_OK="$(cat "$BIND_FLASH")"
  rm -f "$BIND_FLASH"
fi
if [ "$REQUEST_METHOD" = "POST" ]; then
  read -r -n "${CONTENT_LENGTH:-0}" BODY
  action="$(get_param action "$BODY")"
  bind_ok=""
  case "$action" in
    route)
      mac="$(normalize_mac "$(get_param mac "$BODY")")"; ip="$(get_param ip "$BODY")"; outbound="$(get_param outbound "$BODY")"; label="$(get_param label "$BODY" | tr ' ' '_' | sed 's/[^0-9A-Za-z._-]//g')"
      if valid_mac "$mac" && valid_ip "$ip" && [ "$outbound" = "wan" ]; then
        prev_outbound="$(map_outbound "$mac")"
        remove_map "$mac"
        "$APPLY" >/dev/null 2>&1
        if echo "$prev_outbound" | grep -Eq '^dev[0-9][0-9]$' && ! outbound_in_use_by_others "$mac" "$prev_outbound"; then
          restore_outbound_to_placeholder "$prev_outbound" >/dev/null 2>&1 || true
        fi
        message="&#24050;&#35774;&#32622; $mac &#36208;&#26412;&#22320;"
      elif valid_mac "$mac" && valid_ip "$ip" && valid_outbound "$outbound"; then upsert_map "$mac" "$ip" "$outbound" "${label:-device}"; "$APPLY" >/dev/null 2>&1; message="&#24050;&#35774;&#32622; $mac -> $outbound"; else message="MAC/IP/&#20986;&#21475;&#26684;&#24335;&#19981;&#23545;"; fi ;;
    wan)
      mac="$(normalize_mac "$(get_param mac "$BODY")")"; if valid_mac "$mac"; then prev_outbound="$(map_outbound "$mac")"; remove_map "$mac"; "$APPLY" >/dev/null 2>&1; if echo "$prev_outbound" | grep -Eq '^dev[0-9][0-9]$' && ! outbound_in_use_by_others "$mac" "$prev_outbound"; then restore_outbound_to_placeholder "$prev_outbound" >/dev/null 2>&1 || true; fi; message="&#24050;&#35774;&#32622; $mac &#36208;&#26412;&#22320;"; else message="MAC &#22320;&#22336;&#26684;&#24335;&#19981;&#23545;"; fi ;;
    unbind_map)
      mac="$(normalize_mac "$(get_param mac "$BODY")")"; if valid_mac "$mac"; then prev_outbound="$(map_outbound "$mac")"; remove_map "$mac"; "$APPLY" >/dev/null 2>&1; if echo "$prev_outbound" | grep -Eq '^dev[0-9][0-9]$' && ! outbound_in_use_by_others "$mac" "$prev_outbound"; then restore_outbound_to_placeholder "$prev_outbound" >/dev/null 2>&1 || true; fi; message="&#24050;&#21462;&#28040;&#35774;&#22791;&#32465;&#23450;&#65292;$mac &#24050;&#24674;&#22797;&#33258;&#30001;&#19978;&#32593; / &#20027;&#32593;&#32476;&#30452;&#36830;"; else message="MAC &#22320;&#22336;&#26684;&#24335;&#19981;&#23545;"; fi ;;
    apply)
      "$APPLY" >/dev/null 2>&1; message="&#24050;&#37325;&#26032;&#24212;&#29992;&#35268;&#21017;" ;;
    bindout)
      outbound="$(get_param outbound "$BODY")"; ref="$(get_param server_ref "$BODY")"; typ="$(echo "$ref" | cut -d'|' -f1)"; id="$(echo "$ref" | cut -d'|' -f2)"; sub="$(echo "$ref" | cut -d'|' -f3)"
      if valid_outbound "$outbound" && [ "$ref" = "virtual|0|0" ]; then
        message="$outbound &#24403;&#21069;&#26159; 1.1.1.1 &#34394;&#25311;&#21344;&#20301;&#65292;&#21518;&#21488;&#31574;&#30053;&#19981;&#21464;"
      elif valid_outbound "$outbound" && echo "$id" | grep -Eq '^[0-9]+$' && echo "$sub" | grep -Eq '^[0-9]+$' && echo "$typ" | grep -Eq '^(server|subscriptionServer)$'; then
        bootstrap_bind_runtime "$outbound" "$typ" "$id" "$sub" >/dev/null 2>&1 || true
        if /usr/bin/v2raya-bind "$outbound" "$id" "$typ" "$sub" >/dev/null 2>&1; then
          token2="$(api_login)"
          [ -n "$token2" ] && start_runtime_if_possible "$token2" >/dev/null 2>&1 || true
          message="&#24050;&#32465;&#23450; $outbound -> ID$id"
          bind_ok="$outbound"
        else
          message="&#32465;&#23450;&#22833;&#36133;&#65292;&#35831;&#26816;&#26597; ID &#26159;&#21542;&#23384;&#22312;"
        fi
      else message="&#32465;&#23450;&#21442;&#25968;&#19981;&#23545;"; fi ;;
    delete_node)
      ref="$(get_param server_ref "$BODY")"; typ="$(echo "$ref" | cut -d'|' -f1)"; id="$(echo "$ref" | cut -d'|' -f2)"; sub="$(echo "$ref" | cut -d'|' -f3)"
      if [ "$ref" = "virtual|0|0" ]; then
        message="1.1.1.1 &#26159;&#34394;&#25311;&#21344;&#20301;&#65292;&#19981;&#38656;&#35201;&#21024;&#38500;"
      elif echo "$id" | grep -Eq '^[0-9]+$' && echo "$sub" | grep -Eq '^[0-9]+$' && echo "$typ" | grep -Eq '^(server|subscriptionServer)$'; then
        token2="$(api_login)"
        if [ -n "$token2" ]; then
          tmp_delete="/tmp/v2raya-delete-node.$$"
          delete_touch_payload "$typ" "$id" "$sub" > "$tmp_delete"
          resp="$(curl -fsS -m 30 -X DELETE -H "Content-Type: application/json" -H "Authorization: $token2" --data-binary @"$tmp_delete" "$V2RAYA_API/api/touch" 2>/dev/null || true)"
          rm -f "$tmp_delete"
          code="$(printf "%s" "$resp" | jsonfilter -q -e "@.code" 2>/dev/null || true)"
          if [ "$code" = "SUCCESS" ]; then
            message="&#24050;&#21024;&#38500;&#33410;&#28857; ID$id"
          else
            msg="$(printf "%s" "$resp" | jsonfilter -q -e "@.message" 2>/dev/null || true)"
            [ -n "$msg" ] || msg="$resp"
            message="&#21024;&#38500;&#33410;&#28857;&#22833;&#36133;&#65306;$(printf "%s" "$msg" | html_escape)"
          fi
        else
          message="v2rayA &#30331;&#24405;&#22833;&#36133;&#65292;&#26080;&#27861;&#21024;&#38500;&#33410;&#28857;"
        fi
      else message="&#21024;&#38500;&#33410;&#28857;&#21442;&#25968;&#19981;&#23545;"; fi ;;
    delete_nodes)
      delete_refs="$(get_param delete_refs "$BODY")"
      [ -n "$delete_refs" ] || delete_refs="$(get_params_csv delete_ref "$BODY")"
      if [ -z "$delete_refs" ]; then
        message="&#35831;&#20808;&#21246;&#36873;&#35201;&#21024;&#38500;&#30340;&#20195;&#29702;&#33410;&#28857;"
      else
        token2="$(api_login)"
        if [ -n "$token2" ]; then
          tmp_delete="/tmp/v2raya-delete-nodes.$$"
          tmp_touch="/tmp/v2raya-delete-touch.$$"
          tmp_rebind="/tmp/v2raya-delete-rebind.$$"
          curl -fsS -m 10 -H "Authorization: $token2" "$V2RAYA_API/api/touch" > "$tmp_touch" 2>/dev/null || echo '{}' > "$tmp_touch"
          placeholder_ref="$(find_placeholder_ref "$tmp_touch")"
          if [ -z "$placeholder_ref" ]; then
            tmp_ph_link="/tmp/v2raya-placeholder-link.$$"
            tmp_ph_payload="/tmp/v2raya-placeholder-payload.$$"
            printf 'socks5://1.1.1.1:1#VIRTUAL-PLACEHOLDER' > "$tmp_ph_link"
            json_payload_from_file "$tmp_ph_link" > "$tmp_ph_payload"
            curl -fsS -m 30 -H "Content-Type: application/json" -H "Authorization: $token2" --data-binary @"$tmp_ph_payload" "$V2RAYA_API/api/import" >/dev/null 2>&1 || true
            rm -f "$tmp_ph_link" "$tmp_ph_payload"
            curl -fsS -m 10 -H "Authorization: $token2" "$V2RAYA_API/api/touch" > "$tmp_touch" 2>/dev/null || echo '{}' > "$tmp_touch"
            placeholder_ref="$(find_placeholder_ref "$tmp_touch")"
          fi
          ph_typ="$(echo "$placeholder_ref" | cut -d'|' -f1)"
          ph_id="$(echo "$placeholder_ref" | cut -d'|' -f2)"
          ph_sub="$(echo "$placeholder_ref" | cut -d'|' -f3)"
          plan_delete_nodes "$delete_refs" "$tmp_touch" "$tmp_delete" "$tmp_rebind" "$ph_typ" "$ph_id" "$ph_sub"
          if grep -q '^NO_FALLBACK$' "$tmp_rebind" 2>/dev/null; then
            message="&#21024;&#38500;&#33410;&#28857;&#22833;&#36133;&#65306;&#36825;&#20123;&#33410;&#28857;&#27491;&#22312;&#34987;&#20998;&#27969;&#20351;&#29992;&#65292;&#19988;&#27809;&#26377;&#21487;&#29992;&#30340;&#22791;&#29992;&#33410;&#28857;&#21487;&#20999;&#25442;"
          else
            rebind_ok=1
            rebind_count=0
            while read outbound typ id sub; do
              [ -n "$outbound" ] || continue
              tmp_conn="/tmp/v2raya-delete-conn.$$"
              printf '{"id":%s,"_type":"%s","sub":%s,"outbound":"%s"}' "$id" "$typ" "$sub" "$outbound" > "$tmp_conn"
              conn_resp="$(curl -fsS -m 30 -H "Content-Type: application/json" -H "Authorization: $token2" --data-binary @"$tmp_conn" "$V2RAYA_API/api/connection" 2>/dev/null || true)"
              rm -f "$tmp_conn"
              conn_code="$(printf "%s" "$conn_resp" | jsonfilter -q -e "@.code" 2>/dev/null || true)"
              if [ "$conn_code" = "SUCCESS" ]; then
                rebind_count=$((rebind_count + 1))
              else
                rebind_ok=0
                msg="$(printf "%s" "$conn_resp" | jsonfilter -q -e "@.message" 2>/dev/null || true)"
                [ -n "$msg" ] || msg="$conn_resp"
                message="&#21024;&#38500;&#33410;&#28857;&#22833;&#36133;&#65306;&#26080;&#27861;&#20808;&#20999;&#25442; $outbound - $(printf "%s" "$msg" | html_escape)"
                break
              fi
            done < "$tmp_rebind"
            if [ "$rebind_ok" = "1" ]; then
              resp="$(curl -fsS -m 30 -X DELETE -H "Content-Type: application/json" -H "Authorization: $token2" --data-binary @"$tmp_delete" "$V2RAYA_API/api/touch" 2>/dev/null || true)"
              code="$(printf "%s" "$resp" | jsonfilter -q -e "@.code" 2>/dev/null || true)"
              if [ "$code" = "SUCCESS" ]; then
                message="&#24050;&#21024;&#38500;&#21246;&#36873;&#30340;&#20195;&#29702;&#33410;&#28857;&#65292;&#24050;&#30452;&#25509;&#29983;&#25928;"
                [ "$rebind_count" -gt 0 ] && message="$message<br>&#24050;&#20808;&#25226; $rebind_count &#20010;&#20986;&#21475;&#20999;&#21040; 1.1.1.1 &#34394;&#25311;&#21344;&#20301;"
              else
                msg="$(printf "%s" "$resp" | jsonfilter -q -e "@.message" 2>/dev/null || true)"
                [ -n "$msg" ] || msg="$resp"
                message="&#21024;&#38500;&#33410;&#28857;&#22833;&#36133;&#65306;$(printf "%s" "$msg" | html_escape)"
              fi
            fi
          fi
          rm -f "$tmp_delete" "$tmp_touch" "$tmp_rebind"
        else
          message="v2rayA &#30331;&#24405;&#22833;&#36133;&#65292;&#26080;&#27861;&#21024;&#38500;&#33410;&#28857;"
        fi
      fi ;;
    import)
      import_text="$(get_param import_text "$BODY")"
      if [ -n "$(printf '%s' "$import_text" | tr -d '[:space:]')" ]; then
        tmp_import="/tmp/v2raya-import-lines.$$"
        printf '%s' "$import_text" > "$tmp_import"
        summary="$(/usr/bin/v2raya-import-lines "$tmp_import" 2>/dev/null || true)"
        rm -f "$tmp_import"
        if printf '%s' "$summary" | grep -q 'OK='; then
          message="<pre>$(printf '%s' "$summary" | html_escape)</pre>"
        else
          message="&#23548;&#20837;&#22833;&#36133;&#65306;<pre>$(printf '%s' "${summary:-unknown error}" | html_escape)</pre>"
        fi
      else message="&#35831;&#20808;&#31896;&#36148;&#33410;&#28857;&#38142;&#25509;&#25110;&#35746;&#38405;&#22320;&#22336;"; fi ;;
    create_node)
      proto="$(get_param create_protocol "$BODY")"
      name="$(get_param create_name "$BODY")"
      addr="$(get_param create_address "$BODY")"
      port="$(get_param create_port "$BODY")"
      uuid="$(get_param create_uuid "$BODY")"
      password="$(get_param create_password "$BODY")"
      method="$(get_param create_method "$BODY")"
      tls="$(get_param create_tls "$BODY")"
      if [ -n "$addr" ] && echo "$port" | grep -Eq "^[0-9]+$"; then
        link="$(build_node_link "$proto" "$name" "$addr" "$port" "$uuid" "$password" "$method" "$tls" 2>/dev/null || true)"
        if [ -n "$link" ]; then
          token2="$(api_login)"
          tmp_create="/tmp/v2raya-create-node.$$"
          tmp_payload="/tmp/v2raya-create-node-payload.$$"
          printf "%s" "$link" > "$tmp_create"
          if [ -n "$token2" ]; then
            prepare_real_id_slot "$token2"
            json_payload_from_file "$tmp_create" > "$tmp_payload"
            resp="$(curl -fsS -m 120 -H "Content-Type: application/json" -H "Authorization: $token2" --data-binary @"$tmp_payload" "$V2RAYA_API/api/import" 2>/dev/null || true)"
            rm -f "$tmp_create" "$tmp_payload"
            code="$(printf "%s" "$resp" | jsonfilter -q -e "@.code" 2>/dev/null || true)"
            if [ "$code" = "SUCCESS" ]; then
              message="&#24050;sk5&#28155;&#21152;&#20837;&#21475;&#33410;&#28857;&#65292;&#21644; v2rayA &#21518;&#21488;sk5&#28155;&#21152;&#20837;&#21475;&#19968;&#26679;&#65292;&#19981;&#33258;&#21160;&#25913;&#21464;&#20998;&#27969;&#32465;&#23450;"
            else
              msg="$(printf "%s" "$resp" | jsonfilter -q -e "@.message" 2>/dev/null || true)"
              [ -n "$msg" ] || msg="$resp"
              message="sk5&#28155;&#21152;&#20837;&#21475;&#22833;&#36133;&#65306;$(printf "%s" "$msg" | html_escape)"
            fi
          else
            message="v2rayA &#30331;&#24405;&#22833;&#36133;&#65292;&#26080;&#27861;sk5&#28155;&#21152;&#20837;&#21475;"
            rm -f "$tmp_create"
          fi
        else
          message="sk5&#28155;&#21152;&#20837;&#21475;&#22833;&#36133;&#65306;&#21327;&#35758;&#25110;&#21442;&#25968;&#19981;&#25903;&#25345;"
        fi
      else
        message="&#35831;&#22635;&#20889;&#33410;&#28857;&#22320;&#22336;&#21644;&#31471;&#21475;"
      fi ;;
  esac
  printf '%s' "$message" > "$FLASH"
  [ -n "$bind_ok" ] && printf '%s' "$bind_ok" > "$BIND_FLASH"
  printf 'Status: 303 See Other\r\nLocation: /cgi-bin/v2raya-policy\r\nCache-Control: no-store\r\n\r\n'
  exit 0
fi
token="$(api_login)"
touch_file="/tmp/v2raya-policy-touch.$$"
if [ -n "$token" ]; then curl -fsS -m 8 -H "Authorization: $token" "$V2RAYA_API/api/touch" > "$touch_file" 2>/dev/null || echo '{}' > "$touch_file"; else echo '{}' > "$touch_file"; fi
running="$(jsonfilter -q -i "$touch_file" -e '@.data.running' 2>/dev/null || echo false)"
rule_line="$(nft list chain inet v2raya tp_pre 2>/dev/null | grep 'codex-v2raya-device-policy' | head -1)"
status="v2rayA: $running"; [ -n "$rule_line" ] && status="$status / policy ok"
bbr_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
bbr_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
if [ "$bbr_cc" = "bbr" ]; then bbr_badge="&#32593;&#32476;&#21152;&#36895; BBR &#24050;&#24320;&#21551; / V:gg88tk"; else bbr_badge="&#32593;&#32476;&#21152;&#36895; BBR &#26410;&#24320;&#21551; / $bbr_cc"; fi
printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
cat <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>v2rayA &#35774;&#22791;&#20998;&#27969;</title><style>
:root{--bg:#f6f8fb;--panel:#fff;--text:#142033;--muted:#637083;--line:#dfe6ef;--green:#13a36f;--blue:#2167d8;--cyan:#3b9aaa;--amber:#ffd978;--red:#d92d20;--shadow:0 12px 30px rgba(20,32,51,.08)}*{box-sizing:border-box}body{margin:0;font-size:16px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",Arial,sans-serif;background:var(--bg);color:var(--text)}.header{background:#fff;border-bottom:1px solid var(--line)}.wrap{max-width:1320px;margin:0 auto;padding:26px}.top{display:flex;justify-content:space-between;gap:16px;align-items:center}.brand{display:flex;gap:12px;align-items:center}.mark{width:38px;height:38px;border-radius:8px;background:#1f6feb;color:white;display:grid;place-items:center;font-weight:800}.title{font-size:26px;font-weight:760}.sub{font-size:15px;color:var(--muted);margin-top:3px}.pill{border:1px solid var(--line);background:#f9fbfe;border-radius:999px;padding:8px 12px;color:var(--muted);font-size:13px}.grid{display:grid;grid-template-columns:1fr 360px;gap:18px;margin-top:20px}.panel{background:#fff;border:1px solid var(--line);border-radius:8px;box-shadow:var(--shadow)}.panel h2{font-size:19px;margin:0;padding:18px 20px;border-bottom:1px solid var(--line)}.panel-head{display:flex;align-items:center;justify-content:space-between;gap:14px}.panel-tip{flex:1;min-width:0;color:var(--muted);font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.attention{display:inline-flex;align-items:center;margin-left:8px;color:var(--red);font-size:16px;font-weight:800}.head-actions{display:flex;align-items:center;gap:12px}.head-btn{display:inline-flex;align-items:center;justify-content:center;border-radius:7px;background:#ffdc7a;color:#142033;text-decoration:none;font-size:15px;font-weight:760;padding:9px 15px;min-width:72px}.head-btn:hover{background:#ffd15b}.create-box{display:none;margin:0 0 16px;padding:16px;border:1px solid var(--line);border-radius:8px;background:#fbfcfe}.create-box.open{display:block}.create-grid{display:grid;grid-template-columns:150px 1fr 1fr 130px;gap:12px;align-items:end}.create-grid label{display:grid;gap:6px;font-size:14px;color:var(--muted);font-weight:700}.create-grid label.wide{grid-column:span 2}.create-submit{align-self:end}@media(max-width:900px){.create-grid{grid-template-columns:1fr}.create-grid label.wide{grid-column:auto}}.content{padding:18px 20px}.notice{margin:16px 0 0;padding:10px 12px;border:1px solid #cfe2ff;background:#eef6ff;border-radius:8px;color:#235ea8}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:14px 12px;border-bottom:1px solid var(--line);font-size:16px;vertical-align:middle}th{color:var(--muted);background:#fbfcfe}.dev-table tr:nth-child(odd) td{background:#fcfdff}.device{font-weight:720}.device-line{display:flex;align-items:center;gap:10px}.status-dot{width:10px;height:10px;border-radius:50%;display:inline-block;flex:0 0 auto}.status-dot.online{background:#13a36f;box-shadow:0 0 0 4px rgba(19,163,111,.12)}.online-time{display:inline-flex;min-width:78px;color:var(--red);font-weight:800;font-variant-numeric:tabular-nums}.node-name{font-weight:720}.small{font-size:14px;color:var(--muted);margin-top:3px}.route{display:inline-flex;align-items:center;padding:7px 11px;border-radius:999px;font-weight:700;font-size:14px;background:#edf2fa;color:#3e536e}.route.proxy{background:#eaf7f1;color:#087a53}.dev-badge{display:inline-flex;min-width:78px;justify-content:center;border-radius:7px;background:#3b9aaa;color:#fff;font-weight:800;font-size:15px;padding:9px 13px;text-transform:uppercase}.id-badge{display:inline-flex;min-width:58px;justify-content:center;border-radius:7px;background:#fff2bf;color:#6d5200;font-weight:800;font-size:15px;padding:9px 13px}form.inline{display:flex;gap:8px;align-items:center;justify-content:flex-end}.bind-form{justify-content:flex-start}.bind-ok{color:var(--green);font-size:13px;font-weight:760;white-space:nowrap}.node-delete-box{display:grid;gap:10px;margin-bottom:16px;padding:12px;border:1px solid #ffc9c5;background:#fffafa;border-radius:8px}.node-delete-title{font-weight:800;color:var(--red)}.node-delete-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:8px;max-height:142px;overflow:auto}.node-delete-item{display:flex;align-items:center;gap:8px;min-width:0;padding:8px 9px;border:1px solid var(--line);border-radius:7px;background:white;font-size:14px}.node-delete-item span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.node-delete-item input{width:auto}.delete-node{justify-self:start;background:#fff1f0;color:var(--red);border:1px solid #ffc9c5}.delete-node:hover{background:#ffe4e0}select,input,textarea{border:1px solid var(--line);border-radius:7px;padding:11px 12px;font-size:16px;background:white}select{max-width:340px}textarea{width:100%;min-height:118px;resize:vertical;line-height:1.45}button{border:0;border-radius:7px;padding:11px 14px;font-size:16px;font-weight:720;cursor:pointer;color:white;background:var(--blue)}button.wan{background:#53657a}.kv{display:grid;grid-template-columns:92px 1fr;gap:10px;padding:9px 0;border-bottom:1px solid var(--line);font-size:14px}.muted{color:var(--muted)}.footer{padding:14px 22px;color:var(--muted);font-size:12px}.wide{grid-column:1 / -1}.section-note{color:var(--muted);font-size:15px;margin-bottom:12px}.import-actions{display:flex;justify-content:flex-end;margin-top:10px}.import-rows{display:grid;gap:8px;margin-top:10px}.import-row{display:grid;grid-template-columns:88px 150px 1fr;gap:10px;align-items:center;background:#fbfcfe;border:1px solid var(--line);border-radius:7px;padding:8px 10px}.import-row .line-no{font-weight:800;color:var(--muted)}@media(max-width:900px){.grid{grid-template-columns:1fr}.top{align-items:flex-start;flex-direction:column}form.inline{justify-content:flex-start;flex-wrap:wrap}th:nth-child(2),td:nth-child(2){display:none}.attention{display:block;margin:6px 0 0}.wide{grid-column:auto}select{max-width:220px}}
:root{--bg:#f4f7fa;--line:#d9e2ec;--muted:#5b6b7f;--shadow:0 5px 16px rgba(20,32,51,.055)}body{font-size:15px;line-height:1.35}.wrap{max-width:1240px;padding:16px 22px}.header{border-bottom-color:#dbe3ec}.top{min-height:74px}.mark{width:34px;height:34px;border-radius:7px}.title{font-size:23px;letter-spacing:0}.sub{font-size:14px}.pill{padding:7px 11px;border-radius:7px;background:#f7fafc}.grid{grid-template-columns:1fr;gap:13px;margin-top:14px}.panel{border-radius:7px;box-shadow:var(--shadow);overflow:hidden}.panel h2{font-size:17px;line-height:1.25;padding:12px 16px;background:#fbfdff}.content{padding:12px 16px;overflow-x:auto}.section-note{font-size:13px;margin-bottom:10px;color:#6a788a}.notice{margin:12px 0 0;padding:9px 11px;font-size:14px}.attention{font-size:14px;margin-left:6px}.panel-tip{font-size:12px;font-weight:600}.head-actions{gap:8px}.head-btn{height:34px;min-width:64px;padding:7px 12px;border-radius:6px;font-size:13px}table{table-layout:auto}th,td{padding:9px 10px;font-size:14px;line-height:1.3}th{font-size:13px;font-weight:760;white-space:nowrap}.device{font-size:14px}.device-line{gap:8px}.small{font-size:12px;margin-top:2px}.status-dot{width:9px;height:9px}.online-time{min-width:64px;font-size:13px}.route{padding:5px 9px;border-radius:7px;font-size:13px}.dev-badge{min-width:66px;padding:6px 9px;border-radius:6px;font-size:13px}.id-badge{min-width:48px;padding:6px 9px;border-radius:6px;font-size:13px}.node-name{font-size:14px;max-width:360px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}select,input,textarea{border-radius:6px;padding:8px 10px;font-size:14px}select{height:36px;max-width:300px}textarea{min-height:92px;line-height:1.42}button{height:36px;border-radius:6px;padding:8px 12px;font-size:14px}.bind-form{gap:7px;flex-wrap:nowrap}.bind-form select{min-width:280px;max-width:420px}.bind-ok{font-size:12px}.node-delete-box{gap:8px;margin-bottom:12px;padding:10px;background:#fffdfd}.node-delete-title{font-size:14px}.node-delete-list{grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:6px;max-height:116px}.node-delete-item{padding:6px 8px;border-radius:6px;font-size:13px}.delete-node{height:34px}.kv{grid-template-columns:78px 1fr;padding:7px 0;font-size:13px}.footer{padding:10px 22px 16px}.import-actions{margin-top:8px}.wide{grid-column:1/-1}@media(min-width:1100px){.dev-table th:nth-child(1){width:82px}.dev-table th:nth-child(2){width:150px}.dev-table th:nth-child(3){width:78px}.dev-table th:nth-child(4){width:300px}.dev-table th:nth-child(6){width:86px}.grid>section:first-child th:nth-child(1){width:260px}.grid>section:first-child th:nth-child(2){width:170px}.grid>section:first-child th:nth-child(3){width:96px}.grid>section:first-child th:nth-child(4){width:116px}.grid>section:first-child th:nth-child(5){width:310px}.grid>section:first-child th:nth-child(6){width:76px}}@media(max-width:900px){.wrap{padding:14px 12px}.top{min-height:auto}.panel h2{padding:11px 12px}.content{padding:10px 12px}.title{font-size:20px}.bind-form{flex-wrap:wrap}.bind-form select{min-width:220px;max-width:100%}th,td{padding:8px 8px;font-size:13px}button{height:34px}.head-actions{width:100%;justify-content:flex-start}.panel-head{align-items:flex-start;flex-direction:column}.panel-tip{white-space:normal}}
.wrap{max-width:1480px}.node-name{max-width:440px}.bind-form select{min-width:320px;max-width:520px}select{max-width:340px}.kv{grid-template-columns:78px 1fr auto;align-items:center}.kv-action{margin-left:auto}.unbind-btn{height:30px;padding:5px 10px;background:#eef2f7;color:#405166;border:1px solid #d4deea}.unbind-btn:hover{background:#e3e9f2}.top-status{display:flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end}.pill.ok{border-color:#b7ebcf;background:#eefbf4;color:#087a53;font-weight:760}@media(max-width:900px){.kv{grid-template-columns:70px 1fr}.kv-action{grid-column:2;margin-left:0}.bind-form select{min-width:220px;max-width:100%}.top-status{justify-content:flex-start}}
</style></head><body><header class="header"><div class="wrap top"><div class="brand"><div class="mark">V</div><div><div class="title">tiktok&#35774;&#22791;&#20998;&#27969;&#31995;&#32479;</div><div class="sub">&#35774;&#22791;&#32465;&#23450;&#21040;&#35774;&#22791;&#24207;&#21495; &#28982;&#21518;&#32465;&#23450;&#25351;&#23450;&#33410;&#28857;</div></div></div>
HTML
printf '<div class="top-status"><div class="pill ok">%s</div><div class="pill">&#30456;&#20449;&#33258;&#24049; &#29467;&#24636;&#19981;&#29060;&#28779;</div></div></div></header><main class="wrap">' "$bbr_badge"
[ -n "$message" ] && printf '<div class="notice">%s</div>' "$message"
cat <<'HTML'
<div class="grid"><section class="panel wide"><h2>&#22312;&#32447;&#35774;&#22791; -> <span class="attention">&#27880;&#24847; &#25163;&#26426;&#36830;&#19978;wifi &#25165;&#20250;&#26174;&#31034;</span></h2><div class="content"><div class="section-note">&#36825;&#37324;&#20808;&#25351;&#23450;&#21738;&#21488;&#35774;&#22791;&#36208;&#21738;&#20010; &#35774;&#22791;&#20986;&#21475;&#12290;&#26410;&#25351;&#23450;&#30340;&#35774;&#22791;&#22987;&#32456;&#36208;&#26412;&#22320;&#12290;</div><table><thead><tr><th>&#20869;&#32593; IP / &#35774;&#22791;&#21517;</th><th>MAC</th><th>&#22312;&#32447;&#26102;&#38271;</th><th>&#24403;&#21069;&#36335;&#32447;</th><th>DEV</th><th></th></tr></thead><tbody>
HTML
/usr/libexec/v2raya-devices-html.lua
cat <<'HTML'
</tbody></table></div></section><section class="panel wide"><h2 class="panel-head"><span>&#19968;&#38190;&#23548;&#20837;&#20195;&#29702; IP / &#33410;&#28857;</span><span class="panel-tip">&#25903;&#25345;&#21327;&#35758;&#65306;SOCKS5&#65307;&#25903;&#25345;&#26684;&#24335;&#65306;socks5:// &#21644; host|port|user|pass</span><span class="head-actions"><button class="head-btn" type="button" id="createToggle">sk5&#28155;&#21152;&#20837;&#21475;</button><a class="head-btn" href="#importText">&#23548;&#20837;</a></span></h2><div class="content"><form method="post" id="createBox" class="create-box"><input type="hidden" name="action" value="create_node"><div class="create-grid"><label>&#21327;&#35758;<select name="create_protocol"><option value="socks5">SOCKS5</option></select></label><label class="node-label">&#33410;&#28857;&#21517;<input name="create_name" placeholder="HK-01"></label><label>&#22320;&#22336;<input name="create_address" required placeholder="example.com"></label><label>&#31471;&#21475;<input name="create_port" required inputmode="numeric" placeholder="1080"></label><label>&#29992;&#25143;&#21517;<input name="create_uuid" placeholder="&#21487;&#31354;"></label><label>&#23494;&#30721;<input name="create_password" placeholder="&#21487;&#31354;"></label><input type="hidden" name="create_method" value=""><input type="hidden" name="create_tls" value="none"><button class="create-submit" type="submit">&#28155;&#21152;&#21040;ip&#21015;&#34920;</button></div></form><form method="post" id="importForm"><input type="hidden" name="action" value="import"><textarea name="import_text" id="importText" placeholder="socks5://user:pass@example.com:1080#name"></textarea><div class="import-actions"><button type="submit">&#21482;&#23548;&#20837;&#20195;&#29702; IP &#21015;&#34920;</button></div></form></div></section><section class="panel wide"><h2>&#35774;&#22791;&#20986;&#21475;&#32465;&#23450;&#65306;&#35774;&#22791;01-&#35774;&#22791;20 -> &#33410;&#28857; ID</h2><div class="content"><div class="section-note">&#36825;&#37324;&#30340;&#39034;&#24207;&#22266;&#23450;&#20026; &#35774;&#22791;01 &#21040; &#35774;&#22791;20&#12290;&#26032;&#22686;&#33410;&#28857;&#21518;&#65292;&#22312;&#36825;&#37324;&#25226;&#23545;&#24212; &#35774;&#22791; &#32465;&#21040;&#21487;&#29992;&#30340;&#33410;&#28857; ID &#21363;&#21487;&#12290;</div>
HTML
BIND_OK="$BIND_OK" /usr/libexec/v2raya-bind-html.lua "$touch_file" "$MAP"
cat <<'HTML'
</div></section><aside class="panel wide"><h2>&#24403;&#21069;&#35774;&#22791;&#26144;&#23556;</h2><div class="content">
HTML
if [ -s "$MAP" ]; then awk '!/^#/ && NF>=3 {print $1"\t"$2"\t"$3}' "$MAP" | while IFS="$(printf '\t')" read mac ip out; do mac_html="$(printf '%s' "$mac" | html_escape)"; ip_html="$(printf '%s' "$ip" | html_escape)"; if echo "$out" | grep -Eq '^dev[0-9][0-9]$'; then out_html="&#35774;&#22791;${out#dev}"; else out_html="$(printf '%s' "$out" | html_escape)"; fi; printf '<div class="kv"><div class="muted">&#35774;&#22791;</div><div>%s -&gt; %s -&gt; %s</div><form class="kv-action" method="post"><input type="hidden" name="action" value="unbind_map"><input type="hidden" name="mac" value="%s"><button class="unbind-btn" type="submit">&#21462;&#28040;&#32465;&#23450;</button></form></div>' "$mac_html" "$ip_html" "$out_html" "$mac_html"; done; else printf '<div class="muted">&#27809;&#26377;&#35774;&#22791;&#34987;&#25351;&#23450;&#65292;&#20840;&#37096;&#36208;&#26412;&#22320;&#12290;</div>'; fi
cat <<'HTML'
</div></aside></div><div class="footer">&#31574;&#30053;&#19981;&#21464;&#65306;&#35774;&#22791; -> &#35774;&#22791;XX -> &#33410;&#28857; ID&#65307;&#26410;&#25351;&#23450;&#35774;&#22791;&#22987;&#32456;&#36208;&#26412;&#22320;&#12290;</div></main><script>
(function(){
  const ta=document.getElementById('importText');
  const form=document.getElementById('importForm');
  const createToggle=document.getElementById('createToggle');
  const createBox=document.getElementById('createBox');
  const createProto=document.querySelector('select[name="create_protocol"]');
  const compactStyle=document.createElement('style');
  compactStyle.textContent='#createBox{padding:12px 14px;margin-bottom:14px;background:#fcfdff}#createBox .create-grid{grid-template-columns:104px 170px minmax(230px,1fr) 96px minmax(130px,.55fr) minmax(130px,.55fr) 132px;gap:9px 10px;align-items:end}#createBox label{display:grid;font-size:12px;gap:4px;color:#576579;font-weight:700;min-width:0}#createBox .node-label{max-width:170px}#createBox input,#createBox select{width:100%;max-width:none;height:38px;font-size:14px;padding:8px 10px;border-radius:6px}#createBox .create-submit{height:38px;font-size:14px;padding:8px 12px;white-space:nowrap;border-radius:6px}@media(max-width:1180px){#createBox .create-grid{grid-template-columns:104px 170px minmax(220px,1fr) 96px;grid-auto-flow:row}#createBox .create-submit{grid-column:span 2}}@media(max-width:900px){#createBox .create-grid{grid-template-columns:1fr}#createBox .create-submit{grid-column:auto}}';
  document.head.appendChild(compactStyle);
  if(createProto&&!Array.from(createProto.options).some(o=>o.value==='socks5')){
    const opt=document.createElement('option'); opt.value='socks5'; opt.textContent='SOCKS5'; createProto.appendChild(opt);
  }
  if(createToggle&&createBox){createToggle.addEventListener('click',()=>{createBox.classList.toggle('open'); const first=createBox.querySelector('input,select'); if(createBox.classList.contains('open')&&first) first.focus();});}
  const deleteForm=document.getElementById('deleteNodesForm');
  const deleteRefs=document.getElementById('deleteRefs');
  if(deleteForm&&deleteRefs){
    deleteForm.addEventListener('submit',e=>{
      const refs=Array.from(deleteForm.querySelectorAll('.delete-node-check:checked')).map(x=>x.value);
      if(refs.length===0){alert('请先勾选要删除的代理节点'); e.preventDefault(); return;}
      if(!confirm('确认删除已勾选的 '+refs.length+' 个代理节点？删除后不可恢复。')){e.preventDefault(); return;}
      deleteRefs.value=refs.join(',');
    });
  }
  function formatDuration(sec){
    sec=Math.max(0,Math.floor(sec||0));
    const h=Math.floor(sec/3600), m=Math.floor((sec%3600)/60), s=sec%60;
    if(h>0) return h+'&#26102;'+m+'&#20998;'+s+'&#31186;';
    if(m>0) return m+'&#20998;'+s+'&#31186;';
    return s+'&#31186;';
  }
  function tickOnlineTime(){
    const now=Math.floor(Date.now()/1000);
    document.querySelectorAll('[data-online-since]').forEach(el=>{
      const since=Number(el.getAttribute('data-online-since')||0);
      if(since>0) el.innerHTML=formatDuration(now-since);
    });
  }
  tickOnlineTime();
  setInterval(tickOnlineTime,1000);
})();
</script></body></html>
HTML
rm -f "$touch_file"
