# tapo-udp2mqtt

Listen for UDP broadcast packets from Tapo video doorbells (e.g. D235) and translate them into MQTT pulses.

This tool was created to integrate Tapo doorbells into custom home‑automation setups
(ioBroker, Node‑RED, Home Assistant, custom MQTT consumers) **without any cloud dependency**.

---

## What it does

- Listens on a UDP port (default: **20005** or **25005**, depending on model)
- Accepts **broadcast packets only**
- Performs basic sanity checks:
  - minimum packet length
  - source IP filtering (optional)
- When a valid packet is received:
  - publishes MQTT value `1`
  - waits a short delay (default: 500 ms)
  - publishes MQTT value `0`

This produces a clean **momentary MQTT trigger** suitable for automations.

---

## Why this works

Tapo doorbells send a **UDP broadcast packet** when the physical ring button is pressed.
The packet payload is binary and undocumented, but:

- it is only sent on button press
- it is broadcast
- it has a consistent minimum length

So the **existence** of the packet is sufficient as a trigger.

---

## Requirements

- Lua 5.1+
- LuaSocket
- Lua MQTT library (mosquitto or compatible)
- Network access to the doorbell VLAN
- Plain MQTT (no TLS)

---

## Usage

```bash
lua tapo-udp2mqtt.lua \
  --mqtt 192.168.1.10[:1883] \
  --topic house/doorbell/front \
  [--udp-port 20005] \
  [--minlen 20] \
  [--source 192.168.4.] \
  [--pulse-ms 500]
```

---

## Parameters

| Parameter | Description |
|---------|-------------|
| `--mqtt` | MQTT broker IP or IP:port |
| `--topic` | MQTT topic to publish |
| `--udp-port` | UDP listen port (default: 20005) |
| `--minlen` | Minimum UDP packet length |
| `--source` | Optional source IP prefix filter |
| `--pulse-ms` | Pulse duration in milliseconds |

---

## MQTT behaviour

On valid UDP packet:
```
topic = 1
(wait)
topic = 0
```

No retained messages.
QoS 0.

---

## Testing UDP manually

```bash
echo test | nc -u -b 255.255.255.255 20005
```

---

## Security notes

- UDP is unauthenticated
- Use VLAN separation
- Source IP filtering recommended

---

## License

MIT License

---

## Author

Johannes Rietschel
