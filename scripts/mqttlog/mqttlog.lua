#!/usr/bin/env lua
-- mqttlog.lua
-- Subscribe to MQTT topics and print "topic: message" (optional date),
-- optionally also forward each line to a Loki/Alloy push endpoint.

local socket = require("socket")
local http   = require("socket.http")
local ltn12  = require("ltn12")
local mqtt   = require("mqtt")        -- e.g. luarocks install luamqtt

-- ------------------------
-- Helpers
-- ------------------------

local function usage()
  print("Usage:")
  print("  mqttlog.lua [-d] [--loki [url]] <mqtt_host[:port]> <topic1,topic2,...> [topic2 ...]")
  print("")
  print("Examples:")
  print("  mqttlog.lua 192.168.1.12 -d a/gate1,m/door,m/feeder,m/lights/1")
  print("  mqttlog.lua --loki 192.168.1.12 a/gate1,m/door")
  print("  mqttlog.lua --loki http://127.0.0.1:9999/loki/api/v1/push 192.168.1.12 -d a/gate1")
  os.exit(2)
end

local function split_commas(s)
  local out = {}
  for part in tostring(s):gmatch("([^,]+)") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then table.insert(out, part) end
  end
  return out
end

local function ensure_hash(topic)
  if topic:find("[#+]") then return topic end
  if topic:sub(-1) == "/" then return topic .. "#"
  else return topic .. "/#" end
end

local function now_str()
  return os.date("%y%m%d %H:%M:%S")
end

local function now_ns()
  -- Loki wants nanoseconds since epoch as a string
  return tostring(math.floor(socket.gettime() * 1e9))
end

local function json_escape(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
       :gsub("\"", "\\\"")
       :gsub("\r", "\\r")
       :gsub("\n", "\\n")
       :gsub("\t", "\\t")
  -- Strip other control chars
  s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
  return s
end

-- ------------------------
-- Arg parsing
-- ------------------------

if #arg < 2 then usage() end

local with_date = false
local loki_enable = false
local loki_url = "http://127.0.0.1:9999/loki/api/v1/push"

local broker = nil
local topics = {}

local i = 1
while i <= #arg do
  local a = arg[i]

  if a == "-d" then
    with_date = true
    i = i + 1

  elseif a == "--loki" then
    loki_enable = true
    -- optional URL after --loki (if next arg is not another flag and not broker)
    local nxt = arg[i + 1]
    if nxt and not nxt:match("^%-") and (nxt:match("^https?://") ~= nil) then
      loki_url = nxt
      i = i + 2
    else
      i = i + 1
    end

  else
    -- first non-flag is broker, rest are topics (comma-separated or multiple args)
    if not broker then
      broker = a
    else
      if a:find(",") then
        for _, t in ipairs(split_commas(a)) do table.insert(topics, t) end
      else
        table.insert(topics, a)
      end
    end
    i = i + 1
  end
end

if not broker or #topics == 0 then usage() end

-- broker parsing host[:port]
local host, port = broker:match("^([^:]+):(%d+)$")
if not host then
  host = broker
  port = "1883"
end
local uri = ("mqtt://%s:%s"):format(host, port)

-- normalize subscription topics
local sub_topics = {}
for _, t in ipairs(topics) do
  table.insert(sub_topics, ensure_hash(t))
end

-- ------------------------
-- Loki push (optional)
-- ------------------------

local function loki_push(line)
  if not loki_enable then return true end

  -- Keep labels LOW-cardinality. Do NOT put topic/payload in labels.
  local labels = '{\"job\":\"mqttlog\",\"host\":\"' .. json_escape(socket.dns.gethostname() or "host") .. '\"}'
  local ts = now_ns()
  local payload = "{\"streams\":[{\"stream\":" .. labels ..
                  ",\"values\":[[\"" .. ts .. "\",\"" .. json_escape(line) .. "\"]]}]}"

  local resp = {}
  local ok, code = http.request{
    url = loki_url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#payload),
    },
    source = ltn12.source.string(payload),
    sink = ltn12.sink.table(resp),
  }

  if not ok then
    print("LOKI push failed (request error): " .. tostring(code))
    return false
  end
  if tonumber(code) and tonumber(code) >= 300 then
    print("LOKI push failed HTTP " .. tostring(code) .. " body=" .. table.concat(resp))
    return false
  end
  return true
end

-- ------------------------
-- Print + forward
-- ------------------------

local function emit(topic, payload)
  topic = topic or "?"
  payload = (payload == nil) and "" or tostring(payload)

  local line
  if with_date then
    line = string.format("%s %s: %s", now_str(), topic, payload)
  else
    line = string.format("%s: %s", topic, payload)
  end

  print(line)
  loki_push(line)
end

-- ------------------------
-- MQTT client
-- ------------------------

math.randomseed(os.time())
local client = mqtt.client({
  uri = uri,
  id  = ("mqttlog-%d"):format(math.random(1, 1000000000)),
  clean = true,
  keep_alive = 60,
})

client:on({
  connect = function(connack)
    if not connack or connack.rc ~= 0 then
      print("MQTT connect failed rc=" .. tostring(connack and connack.rc))
      return
    end
    for _, t in ipairs(sub_topics) do
      client:subscribe({ topic = t, qos = 0 })
      print("Subscribed to " .. t)
    end
    if loki_enable then
      print("Loki forwarding enabled -> " .. loki_url)
    end
  end,

  message = function(msg)
    emit(msg.topic, msg.payload)
  end,

  error = function(err)
    print("MQTT error: " .. tostring(err))
  end,
})

local ok, err = client:connect()
if not ok then
  print("MQTT connect failed: " .. tostring(err))
  os.exit(1)
end

client:loop_forever()
