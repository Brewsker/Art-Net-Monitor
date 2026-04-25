# Notes — Assumptions & Open Items

## Known Assumptions

- Art-Net traffic is on UDP port 6454 (standard)
- Lighting controller and Elation nodes are on the same UniFi switch or reachable via trunk
- RADIO PC will receive SPAN traffic on its physical Ethernet NIC (Realtek 2.5GbE)
- Wireshark and Npcap are already installed (confirmed during setup)
- tshark is installed but NOT in PATH — full path is: `C:\Program Files\Wireshark\tshark.exe`
- Docker Desktop is NOT yet installed

## Software State (as of initial setup)

| Software       | Status                         |
|----------------|--------------------------------|
| Wireshark      | Installed                      |
| tshark         | Installed (not in PATH)        |
| Npcap          | Installed                      |
| Docker Desktop | NOT installed                  |
| docker CLI     | NOT in PATH                    |

## Things to Verify

- [ ] Which physical port on the UniFi switch is connected to RADIO PC
- [ ] Which ports carry lighting controller + Elation node traffic
- [ ] Whether the capture NIC needs to be on the same VLAN as the lighting network
- [ ] Whether Art-Net traffic is unicast, broadcast, or multicast in this setup
- [ ] If a second NIC is needed (dedicated capture vs. management on same adapter)
- [ ] Whether sACN (UDP 5568) traffic is present or future
- [ ] tshark PATH — add `C:\Program Files\Wireshark` to system PATH if scripting requires it

## Decisions Pending Approval

- [ ] Install Docker Desktop on RADIO PC (optional)
- [ ] Add tshark to system PATH
- [ ] Disable NIC power saving on capture adapter (steps in NETWORK_SETUP.md)
- [ ] Set up SSH key auth to RADIO PC (currently password-based via Tailscale)

## Future Integration Notes

- **OpenClaw / Marceline**: Alert service (Tailscale IP: 100.73.117.27) may consume
  logs from `C:\AV-Monitoring\logs\` — format TBD
- Log shipping method TBD (file watch, syslog, webhook, etc.)
- Grafana/InfluxDB containers defined as placeholders — not yet deployed

## Constraints Recorded

- Packet capture MUST run on the Windows host (Wireshark/Npcap) — never containerized
- Do NOT bridge NICs
- Do NOT modify production network configuration without confirmation
- This system is passive and non-inline
