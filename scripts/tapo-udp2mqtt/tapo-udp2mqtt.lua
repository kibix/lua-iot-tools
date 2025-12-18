#!/usr/bin/env lua
-- UDP doorbell receiver -> MQTT pulse ("1" then pulse_ms later "0")
-- Plain MQTT 3.1.1, QoS0, no TLS.
-- Requires: LuaSocket

local socket = require("socket")

local function usage()
  io.stderr:write([[
Usage:
  lua tapo-udp2mqtt.lua <mqtt_host> <mqtt_topic> [mqtt_port] [udp_port] [min_len] [allowed_prefix] [debounce_s] [pulse_ms] [bind_ip]

Args:
  mqtt_host       MQTT broker IP/host
  mqtt_topic      Topic to publish (payload "1" then "0")
  mqtt_port       default 1883
  udp_port        default 25005
  min_len         default 24        (drop packets shorter than this)
  allowed_prefix  default "192.168.4." (only accept UDP from this IPv4 prefix; set to "" to disable)
  debounce_s      default 1.0       (ignore repeated triggers inside this window)
  pulse_ms        default 500       (duration between "1" and "0")
  bind_ip         default 0.0.0.0   (bind address; set to VLAN IP if you want)

Example:
  lua tapo-udp2mqtt.lua 192.168.66.10 tapo/doorbell 1883 25005 24 192.168.4. 1.0 500 0.0.0.0
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
local PULSE_MS       = tonumber(arg[8] or "500")
local BIND_IP        = arg[9] or "0.0.0.0"

if not mqtt_host or not mqtt_topic then usage() end

-- -------------------------
-- MQTT minimal client (QoS0) with keepalive
-- -------------------------
local function enc_u16(n)
  local hi = math.floor(n / 256)
  local lo = n % 256
  return string.char(hi, lo)
end

local function enc_str(s) return enc_u16(#s) .. s end

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

-- IMPORTANT FIX: correct sendall handling for partial sends
local function sendall(sock, data)
  local i = 1
  while i <= #data do
    local sent, err, last = sock:send(data, i)
    if sent then
      i = i + sent
    else
      if last and last > 0 then
        i = i + last
      else
        return nil, err
      end
    end
  end
  return true
end

local KEEPALIVE = 30

local function mqtt_connect(sock, client_id, keepalive)
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

  sock:settimeout(0) -- non-blocking thereafter
  return true
end

local function mqtt_publish_qos0(sock, topic, payload)
  local vh = enc_str(topic)
  local rl = #vh + #payload
  local pkt = string.char(0x30) .. enc_varint(rl) .. vh .. payload
  return sendall(sock, pkt)
end

local function mqtt_ping(sock)
  return sendall(sock, string.char(0xC0, 0x00))
end

local function mqtt_drain(sock)
  -- discard any pending bytes (PINGRESP, etc.)
  while true do
    local data, err, partial = sock:receive(1024)
    local got = data or partial
    if got and #got > 0 then
      -- discard
    else
      break
    end
  end
end

local mq = nil
local last_mqtt_activity = 0

math.randomseed(os.time() + math.floor(socket.gettime() * 1000))

local function mqtt_open()
  local tcp = assert(socket.tcp())
  tcp:settimeout(4)
  local ok, err = tcp:connect(mqtt_host, mqtt_port)
  if not ok then
    tcp:close()
    return nil, err
  end

  local client_id = ("tapo_udp_%d_%d"):format(math.random(100000, 999999), os.time())
  local ok2, err2 = mqtt_connect(tcp, client_id, KEEPALIVE)
  if not ok2 then
    tcp:close()
    return nil, err2
  end

  last_mqtt_activity = socket.gettime()
  return tcp
end

local function mqtt_close()
  if mq then pcall(function() mq:close() end) end
  mq = nil
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

local function mqtt_pub(payload)
  local s = ensure_mqtt()
  if not s then return false end

  local ok, err = mqtt_publish_qos0(s, mqtt_topic, payload)
  if not ok then
    print(("MQTT publish(%s) failed: %s (reconnect)"):format(payload, err or "closed"))
    mqtt_close()
    s = ensure_mqtt()
    if not s then return false end
    ok, err = mqtt_publish_qos0(s, mqtt_topic, payload)
    if not ok then
      print(("MQTT publish(%s) retry failed: %s"):format(payload, err or "closed"))
      mqtt_close()
      return false
    end
  end

  last_mqtt_activity = socket.gettime()
  return true
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
      mqtt_drain(mq)
    end
  else
    -- also drain opportunistically
    mqtt_drain(mq)
  end
end

-- -------------------------
-- UDP listener
-- -------------------------
local udp = assert(socket.udp())
udp:setoption("reuseaddr", true)
-- rcvbuf is not supported on every platform, ignore failures
pcall(function() udp:setoption("rcvbuf", 262144) end)

assert(udp:setsockname(BIND_IP, udp_port))
udp:settimeout(0) -- we drive timing via sleep/select

local function now_s() return socket.gettime() end

local function allowed_source(ip)
  if not ALLOWED_PREFIX or ALLOWED_PREFIX == "" then return true end
  return ip and ip:sub(1, #ALLOWED_PREFIX) == ALLOWED_PREFIX
end

local last_trigger = 0
local pending_zero_at = nil
local pulse_s = PULSE_MS / 1000.0

print(("Listening UDP %s:%d (min_len=%d, allowed_prefix=%s, debounce=%.2fs)")
  :format(BIND_IP, udp_port, MIN_LEN, (ALLOWED_PREFIX == "" and "<any>" or ALLOWED_PREFIX), DEBOUNCE_S))
print(("MQTT -> %s:%d topic=%s (keepalive=%ds, pulse=%dms)")
  :format(mqtt_host, mqtt_port, mqtt_topic, KEEPALIVE, PULSE_MS))

while true do
  -- Receive as many UDP packets as are queued (non-blocking)
  while true do
    local data, ip, port = udp:receivefrom()
    if not data then break end

    local t = now_s()
    if #data >= MIN_LEN and allowed_source(ip) and (t - last_trigger) >= DEBOUNCE_S then
      last_trigger = t
      local ts = os.date("%y%m%d-%H:%M:%S")
      print(("%s: UDP trigger from %s:%s len=%d -> MQTT pulse")
        :format(ts, ip or "?", tostring(port), #data))

      -- Non-blocking pulse: publish 1 now, schedule 0 later
      if mqtt_pub("1") then
        pending_zero_at = t + pulse_s
      end
    end
  end

  -- If we owe a "0", send it when time is reached
  if pending_zero_at and now_s() >= pending_zero_at then
    mqtt_pub("0")
    pending_zero_at = nil
  end

  tick_keepalive()

  -- small sleep to avoid busy loop but still responsive
  socket.sleep(0.02)
end

