#!/usr/bin/env lua
-- UDP doorbell receiver (port 25005) -> MQTT pulse ("1" then 500ms later "0")
-- Mosquitto plain TCP, no TLS, QoS0 only.
-- Requires: LuaSocket (luasocket)

local socket = require("socket")

-- -------------------------
-- Usage / args
-- -------------------------
local function usage()
  io.stderr:write([[
Usage:
  lua udp25005_to_mqtt.lua <mqtt_host> <mqtt_topic> [mqtt_port] [udp_port] [min_len] [allowed_prefix] [debounce_s]

Args:
  mqtt_host       MQTT broker IP/host
  mqtt_topic      Topic to publish (payload "1" then "0")
  mqtt_port       default 1883
  udp_port        default 25005
  min_len         default 24  (drop packets shorter than this)
  allowed_prefix  default "192.168.4."  (only accept UDP from this IPv4 prefix)
  debounce_s      default 1.0 (ignore repeated triggers inside this window)

Example:
  lua udp25005_to_mqtt.lua 192.168.66.10 tapo/doorbell 1883 25005 24 192.168.4. 1.0
]])
  os.exit(2)
end

local mqtt_host      = arg[1]
local mqtt_topic     = arg[2]
local mqtt_port      = tonumber(arg[3] or "1883")
local udp_port       = tonumber(arg[4] or "25005")
local MIN_LEN        = tonumber(arg[5] or "24")
local ALLOWED_PREFIX = arg[6] or "192.168.4."
local DEBOUNCE_S     = tonumber(arg[7] or "1.0")

if not mqtt_host or not mqtt_topic then usage() end

-- -------------------------
-- MQTT minimal 3.1.1 client (QoS0) with keepalive + sendall
-- -------------------------
local function enc_u16(n)
  local hi = math.floor(n / 256)
  local lo = n % 256
  return string.char(hi, lo)
end

local function enc_str(s)
  return enc_u16(#s) .. s
end

local function enc_varint(n)
  local out = {}
  repeat
    local digit = n % 128
    n = math.floor(n / 128)
    if n > 0 then digit = digit + 128 end
    out[#out+1] = string.char(digit)
  until n == 0
  return table.concat(out)
end

local function sendall(sock, data)
  local i = 1
  while i <= #data do
    local sent, err = sock:send(data, i)
    if not sent then return nil, err end
    i = sent + 1
  end
  return true
end

local KEEPALIVE = 30  -- seconds

local function mqtt_connect(sock, client_id, keepalive)
  -- CONNECT packet
  local vh = enc_str("MQTT") .. string.char(0x04) .. string.char(0x02) .. enc_u16(keepalive)
  local pl = enc_str(client_id)
  local rl = #vh + #pl
  local pkt = string.char(0x10) .. enc_varint(rl) .. vh .. pl

  local ok, err = sendall(sock, pkt)
  if not ok then return nil, err end

  -- CONNACK
  sock:settimeout(3)
  local b1 = sock:receive(1)
  if not b1 then return nil, "No CONNACK" end
  if b1:byte(1) ~= 0x20 then return nil, "Unexpected CONNACK header" end
  local rl_b = assert(sock:receive(1)):byte(1)
  if rl_b ~= 0x02 then return nil, "Unexpected CONNACK length" end
  assert(sock:receive(1)) -- flags
  local rc = assert(sock:receive(1)):byte(1)
  if rc ~= 0 then return nil, ("CONNACK rc=%d"):format(rc) end
  sock:settimeout(1)
  return true
end

local function mqtt_publish_qos0(sock, topic, payload)
  -- PUBLISH QoS0, retain=0: 0x30
  local vh = enc_str(topic)
  local pl = payload
  local rl = #vh + #pl
  local pkt = string.char(0x30) .. enc_varint(rl) .. vh .. pl
  return sendall(sock, pkt)
end

local function mqtt_ping(sock)
  return sendall(sock, string.char(0xC0, 0x00)) -- PINGREQ
end

-- connection state
local mq = nil
local last_mqtt_activity = 0

local function mqtt_open()
  local tcp = assert(socket.tcp())
  tcp:settimeout(4)
  local ok, err = tcp:connect(mqtt_host, mqtt_port)
  if not ok then
    tcp:close()
    return nil, err
  end

  local client_id = ("udp25005_%d_%d"):format(math.random(100000, 999999), os.time())
  local ok2, err2 = mqtt_connect(tcp, client_id, KEEPALIVE)
  if not ok2 then
    tcp:close()
    return nil, err2
  end

  last_mqtt_activity = socket.gettime()
  return tcp
end

local function ensure_mqtt()
  if mq then return mq end
  local s, err = mqtt_open()
  if not s then
    print(("MQTT connect failed: %s"):format(err or "unknown"))
    return nil
  end
  mq = s
  return mq
end

local function mqtt_close()
  if mq then
    pcall(function() mq:close() end)
    mq = nil
  end
end

local function tick_keepalive()
  if not mq then return end
  local t = socket.gettime()
  if (t - last_mqtt_activity) >= (KEEPALIVE / 2) then
    local ok, err = mqtt_ping(mq)
    if not ok then
      print(("MQTT ping failed: %s"):format(err or "closed"))
      mqtt_close()
    else
      last_mqtt_activity = t
    end
  end
end

local function mqtt_pulse(topic)
  local s = ensure_mqtt()
  if not s then return false end

  local ok1, e1 = mqtt_publish_qos0(s, topic, "1")
  if not ok1 then
    print(("MQTT publish(1) failed: %s (reconnect)"):format(e1 or "closed"))
    mqtt_close()
    s = ensure_mqtt()
    if not s then return false end
    ok1, e1 = mqtt_publish_qos0(s, topic, "1")
    if not ok1 then
      print(("MQTT publish(1) retry failed: %s"):format(e1 or "closed"))
      mqtt_close()
      return false
    end
  end
  last_mqtt_activity = socket.gettime()

  socket.sleep(0.5)

  local ok0, e0 = mqtt_publish_qos0(s, topic, "0")
  if not ok0 then
    print(("MQTT publish(0) failed: %s (reconnect)"):format(e0 or "closed"))
    mqtt_close()
    s = ensure_mqtt()
    if not s then return false end
    ok0, e0 = mqtt_publish_qos0(s, topic, "0")
    if not ok0 then
      print(("MQTT publish(0) retry failed: %s"):format(e0 or "closed"))
      mqtt_close()
      return false
    end
  end
  last_mqtt_activity = socket.gettime()

  return true
end

-- -------------------------
-- UDP listener
-- -------------------------
math.randomseed(os.time() + math.floor(socket.gettime() * 1000))

local udp = assert(socket.udp())
assert(udp:setsockname("0.0.0.0", udp_port))
udp:settimeout(0.25)

local function now_s()
  return socket.gettime()
end

local function allowed_source(ip)
  return ip and ip:sub(1, #ALLOWED_PREFIX) == ALLOWED_PREFIX
end

local last_trigger = 0

print(("Listening UDP :%d (min_len=%d, allowed_prefix=%s, debounce=%.2fs)")
  :format(udp_port, MIN_LEN, ALLOWED_PREFIX, DEBOUNCE_S))
print(("MQTT -> %s:%d topic=%s (keepalive=%ds)")
  :format(mqtt_host, mqtt_port, mqtt_topic, KEEPALIVE))

while true do
  local data, ip, port = udp:receivefrom()

  if data then
    local t = now_s()
    if #data >= MIN_LEN and allowed_source(ip) and (t - last_trigger) >= DEBOUNCE_S then
      last_trigger = t
      local ts = os.date("%y%m%d-%H:%M:%S")
      print(("%s: UDP trigger from %s:%s len=%d -> MQTT pulse")
          :format(ts, ip or "?", tostring(port), #data))
      mqtt_pulse(mqtt_topic)
    end
  end

  tick_keepalive()
end
