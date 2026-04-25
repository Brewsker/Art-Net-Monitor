# Art-Net Drop Detection — Technical Reference

## How Universe Drops Are Detected

The monitor tracks the last-seen timestamp for every Art-Net universe it receives.
On each check interval (default 500ms), it compares `Now - LastSeen` against `timeout_seconds`.
If `Now - LastSeen > timeout_seconds`, the universe is declared **dropped** and an ALERT is written.

When the universe resumes (next packet arrives), a **RECOVERY** entry is written and the timeout clock resets.

### Parameters (config.json)

| Setting | Default | Meaning |
|---------|---------|---------|
| `timeout_seconds` | 2 | Seconds of silence before ALERT is raised |
| `startup_grace_seconds` | 5 | Grace window at startup; no ALERT for universes not yet seen within this window |
| `check_interval_ms` | 500 | How often the timeout check runs (ms) |
| `expected_universes` | [0,1,2,3] | Universes monitored — alerts raised if these go missing |

---

## Universe Identification

Art-Net uses a **15-bit Port-Address** to identify each universe:

```
PortAddress = (Net[6:0] << 8) | SubUni[7:0]
```

- `Net` (bits 8–14): set by the "Net" switch on the node or controller
- `SubUni` (bits 0–7): the sub-universe (low byte)

For most installations using a single controller with no sub-net/net offset:
- Universe 0 = PortAddress 0 (Net=0, SubUni=0)
- Universe 1 = PortAddress 1 (Net=0, SubUni=1)
- Universe 4 = PortAddress 4, etc.

If your controller uses a non-zero Net, universes will appear with higher numbers
(e.g., Net=1 gives universe 256, 257, 258...). Adjust `expected_universes` in
config.json accordingly.

---

## Alert Entry Format

All alerts are written to `C:\AV-Monitoring\logs\alerts.log` and to the console.

```
[TYPE] [YYYY-MM-DD HH:MM:SS] Message
```

| Type | Color | Meaning |
|------|-------|---------|
| `ALERT` | Red | Universe dropped below threshold or never seen after grace period |
| `RECOVERY` | Green | Dropped universe resumed sending packets |
| `WARN` | Yellow | Duplicate source IP detected for a universe |
| `INFO` | Cyan | Monitor start/stop, first-seen universe, normal informational events |

**Example log entries:**
```
[INFO]     [2025-07-15 19:30:00] Monitor started — interface:8  universes:0,1,2,3  timeout:2s
[INFO]     [2025-07-15 19:30:01] Universe 0 first seen from 192.168.1.50
[ALERT]    [2025-07-15 19:31:45] Universe 1 missing for >2s (last seen: 19:31:43)
[RECOVERY] [2025-07-15 19:31:50] Universe 1 resumed (from 192.168.1.50)
[WARN]     [2025-07-15 19:32:10] Duplicate source for Universe 0 — IPs: 192.168.1.50, 192.168.1.51
```

---

## Limitations

| Limitation | Detail |
|------------|--------|
| **tshark dependency** | Requires Wireshark installed at `C:\Program Files\Wireshark\tshark.exe`. Npcap must be installed and licensed for capture. |
| **Snaplen** | Capture uses `-s 80` (first 80 bytes per packet). This is sufficient for the Art-Net header but DMX channel values are not captured. Change to `-s 0` in the script if full payload is needed. |
| **Art-Net dissector** | Primary universe extraction uses Wireshark's built-in `artnet.artdmx.universe` field. If the dissector is unavailable (unusual), the fallback parser reads the raw UDP payload bytes 14–15. |
| **No multi-NIC** | The monitor captures on a single interface. If Art-Net traffic is split across multiple NICs, run a separate monitor instance for each. |
| **No persistence** | Universe state is in memory only. If the monitor is restarted, drop history is lost. |
| **Rate limiting** | tshark processes packets sequentially. At extreme packet rates (>10,000 pps), some packets may be dropped by tshark before reaching the script. For high-density rigs, use ring-buffer capture (shortcut 3) and analyse offline. |
| **sACN** | sACN (E1.31, UDP 5568) is not monitored by this script. Use `start-sacn-capture.ps1` for raw sACN capture. |

---

## Duplicate Source Detection

When a universe is being sent from more than one source IP, a `WARN` entry is logged.
This happens once per monitor session per universe (resets on RECOVERY).

Common causes:
- Two lighting consoles both transmitting the same universe (takeover situation)
- A node echoing Art-Net back onto the network
- IP address conflict between controllers

---

## Interpreting the Status Summary

Every 30 seconds the monitor prints a status line to the console (not logged):

```
--- Status @ 19:45:00  uptime:120s  packets:5280 ---
  Universe 0  OK       last:0s ago  sources:1
  Universe 1  OK       last:0s ago  sources:1
  Universe 2  DROPPED  last:8s ago  sources:1
  Universe 3  [not yet seen]
```

- `last:Xs ago` — seconds since the most recent packet for that universe
- `sources:N` — distinct source IPs seen for that universe
- `DROPPED` — an unrecovered ALERT is active
- `[not yet seen]` — expected universe, never received
