# Troubleshooting Guide

## Scenario 1 — No Art-Net packets visible in verify-artnet-traffic.ps1

**Symptom:** Script runs for 30 seconds, no packets appear.

**Most likely cause:** UniFi SPAN mirror is not configured or not pointing to the correct port.

**Check these things:**

1. **UniFi SPAN config**
   - Log in to UniFi Network Controller
   - Navigate to Devices → [Switch] → Ports
   - Confirm the destination port (connected to RADIO PC) has port mirroring enabled
   - Confirm the source ports (lighting controller + Elation nodes) are selected as mirror sources
   - Apply and save

2. **Physical connection**
   - Confirm the Ethernet cable from the UniFi switch SPAN port is plugged into RADIO PC's NIC
   - Check `Get-NetAdapter` — the Ethernet adapter should show **Status: Up**

3. **Wrong interface ID**
   - Re-run `.\list-interfaces.ps1` and confirm you are using the correct number
   - The Realtek adapter is the physical capture NIC

4. **No active Art-Net traffic**
   - Art-Net is only transmitted when a lighting controller is actively sending data
   - If the controller is idle or powered off, no packets will appear
   - Try triggering a scene or channel change on the lighting console to generate traffic

---

## Scenario 2 — Packets visible but traffic is incomplete or inconsistent

**Symptom:** Some packets appear but counts are lower than expected, or some nodes seem missing.

**Possible causes:**

1. **Partial SPAN source port selection**
   - Only some ports may be mirrored
   - Verify ALL relevant switch ports are included as mirror sources (controller + all nodes)

2. **High traffic rate dropping packets**
   - Art-Net can produce 44 universes × 44fps = high packet rate
   - The Realtek 2.5GbE adapter should handle this, but check for interface errors:
     ```powershell
     Get-NetAdapterStatistics -Name "Ethernet"
     ```
   - If `ReceivedPacketErrors` is high, consider disabling NIC power saving (see NETWORK_SETUP.md)

3. **Broadcast vs. unicast Art-Net**
   - Art-Net can be sent as broadcast (255.255.255.255) or unicast to specific node IPs
   - If the controller uses directed unicast, only ports receiving that unicast traffic need mirroring

---

## Scenario 3 — Traffic was visible, then disappeared

**Symptom:** Capture was working, now nothing is seen.

**Check:**

1. **UniFi switch rebooted or config reset** — SPAN settings may not persist through some firmware updates; recheck the mirror config
2. **RADIO PC NIC went to sleep** — disable power saving per NETWORK_SETUP.md
3. **Lighting controller powered off or network disconnected**
4. **tshark process crashed** — check for errors in the terminal; restart the capture script

---

## Scenario 4 — Universe dropouts (traffic visible but universes missing frames)

**Symptom:** Capture file shows Art-Net packets, but fixture behavior shows dropouts or glitches during events.

This is a deeper analysis scenario. Steps:

1. Open the capture `.pcapng` in Wireshark
2. Filter: `udp.port == 6454`
3. Look for:
   - **Large gaps** in frame timestamps from a specific source IP (controller silence)
   - **Duplicate packets** or **retransmits** (network loop or duplicate path)
   - **ARP storms** or **broadcast floods** unrelated to Art-Net (switch overload)
4. Note the source IP(s) and universe numbers (bytes 14–15 of the Art-Net payload are the Universe field)
5. Correlate timestamps with when the dropout was observed on stage

---

## Scenario 5 — tshark exits immediately or reports an error

**Symptom:** Script starts, tshark immediately exits with non-zero code.

**Check:**

1. **Npcap not installed or not running**
   ```powershell
   Test-Path "C:\Windows\System32\Npcap"
   ```
   Should return `True`. If not, reinstall Wireshark with Npcap option checked.

2. **Interface ID is wrong** — run `.\list-interfaces.ps1` to confirm

3. **Permission issue** — run PowerShell as Administrator

4. **Npcap service not started**
   ```powershell
   Get-Service -Name npcap
   ```
   Should be `Running`. If stopped: `Start-Service npcap`

---

## Quick Reference — Useful Commands

```powershell
# List interfaces
.\list-interfaces.ps1

# Check NIC status
Get-NetAdapter | Select-Object Name, Status, LinkSpeed

# Check NIC errors
Get-NetAdapterStatistics -Name "Ethernet"

# Verify Npcap is installed
Test-Path "C:\Windows\System32\Npcap"

# Verify Npcap service is running
Get-Service -Name npcap

# Quick manual tshark test (10 seconds, any traffic)
& "C:\Program Files\Wireshark\tshark.exe" -i 1 -a duration:10
```
