# tapo-udp2mqtt

Receive **Tapo video doorbell ring events** via local UDP broadcast and forward them as an **MQTT pulse**.

This tool listens for a **binary UDP broadcast on port 20005** sent by Tapo video doorbells
(e.g. **D235**, very likely others) **when the ring button is pressed**, and translates this
event into an MQTT message (`"1"` followed by `"0"` after 500 ms).

> ⚠️ **Important**
> - The correct UDP port is **20005**
> - Earlier references to `25005` are wrong
> - The UDP payload is opaque binary data — only presence, length and source IP are used

---

## How it works

- Tapo doorbells emit a **UDP broadcast to port 20005** on ring button press
- Payload is encrypted / undocumented binary data
- Observed properties:
  - Broadcast packet
  - Always sent on button press
  - Not sent for motion or other events

This script:

1. Binds a UDP socket (default `0.0.0.0:20005`, configurable)
2. Filters packets by:
   - Minimum packet length
   - Source IP prefix (useful for VLANs)
   - Debounce window
3. Publishes an MQTT pulse:
   - `topic = "1"`
   - wait 500 ms
   - `topic = "0"`

---

## Requirements

- Lua 5.1 or newer
- LuaSocket (`luasocket`)
- Plain MQTT broker (Mosquitto, no TLS)

### Install LuaSocket (Debian / Ubuntu)

```bash
sudo apt install lua-socket
```

---

## Usage

```bash
lua tapo-udp2mqtt.lua <mqtt_host> <mqtt_topic> [mqtt_port] [udp_port] [min_len] [allowed_prefix] [debounce_s] [bind_ip]
```

> Note: If your script version expects `bind_ip` earlier in the argument list, keep your local script and README in sync.
> The intent is: **bind address is configurable** (default `0.0.0.0`).

---

## Parameters

| Parameter | Default | Description |
|---------|--------|-------------|
| `mqtt_host` | — | MQTT broker IP or hostname |
| `mqtt_topic` | — | Topic to publish pulse to |
| `mqtt_port` | `1883` | MQTT TCP port |
| `udp_port` | `20005` | **Tapo doorbell UDP port** |
| `min_len` | `24` | Drop packets shorter than this |
| `allowed_prefix` | `192.168.4.` | Source IP prefix filter |
| `debounce_s` | `1.0` | Ignore repeated presses inside this window |
| `bind_ip` | `0.0.0.0` | Local bind address for UDP socket |

### When would you use `bind_ip`?

Normally `0.0.0.0` is correct (listen on all interfaces, including VLANs).

You might set `bind_ip` if you want to **restrict** listening to a single interface address, e.g.:

- `192.168.4.10` to listen only on the VLAN IP
- `127.0.0.1` (usually not useful here)

---

## Example

Listen on all interfaces (recommended):

```bash
lua tapo-udp2mqtt.lua 192.168.66.10 tapo/doorbell 1883 20005 24 192.168.4. 1.0 0.0.0.0
```

Restrict to VLAN IP only:

```bash
lua tapo-udp2mqtt.lua 192.168.66.10 tapo/doorbell 1883 20005 24 192.168.4. 1.0 192.168.4.10
```

---

## MQTT behavior

On a valid doorbell press:

```
tapo/doorbell 1
(wait 500 ms)
tapo/doorbell 0
```

This pulse-style signaling works well for:
- ioBroker
- Home Assistant
- Node-RED
- Grafana / alerts
- Any edge-triggered automation

---

## VLAN & broadcast notes

- UDP broadcast arrives on the **Layer-2 network/VLAN** where the doorbell resides
- Linux receives broadcasts on all interfaces bound to `0.0.0.0`
- Routers **do not forward broadcasts** by default

Ensure:
- Listener is on the same VLAN **or**
- A broadcast helper / relay is configured

---

## Debugging

### Verify UDP packets

```bash
nc -lu 20005
```

or

```bash
sudo tcpdump -ni any udp port 20005
```

If you see binary garbage when pressing the button, the script will work.

---

## Common mistakes

| Symptom | Cause |
|------|------|
| Script silent | Wrong port (25005 instead of **20005**) |
| `nc` works but script doesn't | IP prefix filter mismatch, or bound to wrong `bind_ip` |
| Only triggers once | Debounce time too long |
| MQTT publish fails | Broker closed idle connection |

---

## Why MQTT pulse instead of JSON?

- Stateless
- Easy edge detection
- No retained garbage
- Works with nearly every automation stack

---

## License

MIT License — do whatever you want, attribution appreciated.

---

## Author

Johannes Rietschel  
Real-world automation, energy & embedded systems
