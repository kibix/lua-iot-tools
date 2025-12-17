# mqttlog

Subscribe to MQTT topics and output messages to stdout and/or Grafana Loki.

---

## Synopsis

```bash
mqttlog [-d] [--loki [URL]] <mqtt_host[:port]> <topic[,topic...] | topic ...>
```

---

## Description

**mqttlog** is a small command-line utility written in Lua that subscribes to one or more MQTT topics and outputs each received message as a log line.

Each incoming MQTT message is written to standard output in a human-readable form:

```
topic: payload
```

Optionally, a timestamp can be prepended, and log lines can additionally be forwarded to a Grafana Loki instance (for example via an Alloy or Loki proxy).

---

## Features

- Subscribe to multiple MQTT topics
- Automatic wildcard subscription (`/#`)
- Optional timestamp prefix
- Optional forwarding to Grafana Loki
- Plain stdout output

---

## Options

### -d

Enable timestamped output (`YYMMDD HH:MM:SS`).

### --loki [URL]

Forward logs to Grafana Loki.
Default URL: `http://127.0.0.1:9999/loki/api/v1/push`

---

## Arguments

### mqtt_host[:port]

MQTT broker address. Default port is 1883.

### topic[,topic...]

One or more topic prefixes. `/#` is appended automatically.

---


## Output format

Without `-d`:
```
topic: payload
```

With `-d`:
```
YYMMDD HH:MM:SS topic: payload
```

---

## Examples

```bash
mqttlog 192.168.1.12 a/gate1,m/door
mqttlog -d --loki 192.168.1.12 m/door
```

---

## Dependencies

- Lua 5.1+
- LuaSocket
- Lua MQTT library

---

## Author

Johannes Rietschel
