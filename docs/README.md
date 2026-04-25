# Art-Net Monitor — RADIO PC

## Purpose

This system provides passive monitoring of Art-Net (DMX-over-IP) network traffic on the A/V network.
It captures UDP packets mirrored from the UniFi switch and provides visibility into lighting controller
communication, Elation node traffic, and potential network faults.

This system is **read-only and non-inline**. It does not transmit Art-Net or interfere with production lighting.

---

## High-Level Architecture

```
[Lighting Controller]
        |
[Elation Nodes]          <-- Art-Net UDP 6454
        |
[UniFi Switch] ---------> [SPAN/Mirror Port]
                                   |
                         [RADIO PC - ThinkCentre]
                           Windows 10 Host
                                   |
                    +--------------+-------------+
                    |                            |
             [Wireshark / tshark]         [Docker Services]
              (host-level capture)        (logs, alerts, viz)
                    |
              C:\AV-Monitoring\captures\
```

**Capture runs on the Windows host** (Wireshark/Npcap/tshark) — never containerized.  
Supporting services (Grafana, InfluxDB, alerting) may run in Docker containers.

---

## Folder Structure

```
C:\AV-Monitoring\
  ├─ captures\     # Raw .pcap files from tshark captures
  ├─ logs\         # Parsed logs, alert outputs
  ├─ scripts\      # PowerShell and Python helper scripts
  ├─ docker\       # docker-compose.yml and container configs
  └─ docs\         # This documentation
```

---

## Quick Start

All scripts live in `C:\AV-Monitoring\scripts\`.
tshark path: `C:\Program Files\Wireshark\tshark.exe` (not in system PATH).

### Step 1 — Identify your capture interface

```powershell
cd C:\AV-Monitoring\scripts
.\list-interfaces.ps1
```

Look for the **Realtek** or mirror-port adapter. Note the number on the left (e.g. `1`).  
Ignore Tailscale, Bluetooth, and loopback.

### Step 2 — Verify Art-Net traffic is visible

```powershell
.\verify-artnet-traffic.ps1 -InterfaceId 1
```

Listens for 30 seconds. If packets appear, the SPAN mirror is working.  
If nothing appears, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### Step 3 — Start rolling capture (ring buffer)

```powershell
.\start-artnet-capture.ps1 -InterfaceId 1
```

Saves `.pcapng` files to `C:\AV-Monitoring\captures\`  
Default: 48 files × 5 minutes = ~4 hours of rolling history.

### Step 4 — Quick text log (no Wireshark needed)

```powershell
.\start-basic-artnet-log.ps1 -InterfaceId 1
```

Prints `timestamp | src IP | dst IP | length` to console and appends to:  
`C:\AV-Monitoring\logs\artnet_log.txt`

### Step 5 — sACN capture (optional / future)

```powershell
.\start-sacn-capture.ps1 -InterfaceId 1
```

Saves sACN (UDP 5568) captures to `C:\AV-Monitoring\captures\`

---

## Opening Captures in Wireshark

1. Open Wireshark
2. **File → Open** → navigate to `C:\AV-Monitoring\captures\`
3. Select a `.pcapng` file
4. Apply display filter: `udp.port == 6454` for Art-Net or `udp.port == 5568` for sACN
5. Right-click a packet → **Follow → UDP Stream** to inspect payload

---

## Where Files Are Saved

| Type           | Path                                  |
|----------------|---------------------------------------|
| Capture files  | `C:\AV-Monitoring\captures\`          |
| Text logs      | `C:\AV-Monitoring\logs\artnet_log.txt`|
| Scripts        | `C:\AV-Monitoring\scripts\`           |

---

## Protocol Reference

| Protocol | Transport | Port  | Notes                    |
|----------|-----------|-------|--------------------------|
| Art-Net  | UDP       | 6454  | Primary target           |
| sACN     | UDP       | 5568  | Future / optional        |

---

---

## Phase 3 — Universe Monitoring and Alerting

### Configuration

Edit `C:\AV-Monitoring\config.json` before starting the monitor:

```json
{
  "capture": { "interface_id": 8, "filter": "udp port 6454" },
  "monitoring": {
    "expected_universes": [0, 1, 2, 3],
    "timeout_seconds": 2,
    "startup_grace_seconds": 5,
    "duplicate_source_warn": true
  }
}
```

Set `interface_id` to your SPAN capture NIC (run `list-interfaces.ps1` to confirm).  
Set `expected_universes` to the universes your rig should always be sending.

### Start the Monitor

```powershell
cd C:\AV-Monitoring\scripts
.\start-universe-monitor.ps1
```

Or use desktop shortcut **AV - 7. Start Universe Monitor**.

The monitor will:
- Log `[INFO]` when each universe is first seen
- Log `[ALERT]` if a universe goes silent for more than `timeout_seconds`
- Log `[RECOVERY]` when a dropped universe resumes
- Log `[WARN]` if multiple source IPs are sending the same universe

### View Alerts

In a second PowerShell window:

```powershell
.\artnet-alerts.ps1 -Follow
```

Or use desktop shortcut **AV - 8. View Alerts Log**.

Color coding: `ALERT` = Red, `RECOVERY` = Green, `WARN` = Yellow, `INFO` = Cyan.

### Alerts Log Location

```
C:\AV-Monitoring\logs\alerts.log
```

### Diagnostic Parsing (optional)

See raw parsed packets without universe tracking:

```powershell
.\parse-artnet.ps1 -InterfaceId 8
```

Useful for verifying the pipeline works before enabling full monitoring.

### Loopback Self-Test (Phase 3)

1. Run `artnet-generator.ps1 -DestinationIP 127.0.0.1 -DurationSeconds 0` (shortcut 6)
2. Edit `config.json`: set `interface_id` to 10 (loopback), `expected_universes` to [0]
3. Run `start-universe-monitor.ps1`
4. Stop the generator — observe the ALERT after ~2s
5. Restart the generator — observe the RECOVERY

---

## Related Docs

- [NETWORK_SETUP.md](NETWORK_SETUP.md) — UniFi SPAN configuration
- [NOTES.md](NOTES.md) — Assumptions and open questions
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — What to check when things go wrong
- [DETECTION.md](DETECTION.md) — Drop detection logic, alert formats, limitations
