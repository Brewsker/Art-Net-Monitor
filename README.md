# Art-Net Monitor PC

## Overview
Remote monitoring and management setup for a Windows 10 Pro machine used as an Art-Net/DMX monitoring station.

---

## Target Machine

| Property       | Value                        |
|----------------|------------------------------|
| Hostname       | DESKTOP-265DQFR              |
| Display Name   | RADIO PC                     |
| OS             | Windows 10 Pro (Build 19045.6466) |
| Local Account  | `RADIO PC` (Administrator, Local Account) |
| LAN IP         | 192.168.1.115                |
| Tailscale IP   | 100.122.223.46               |

---

## Network

The dev machine (`kylesdesktop`, 192.168.10.x) is on a different LAN subnet than RADIO PC (192.168.1.x), so direct LAN routing is not available. All remote access is via **Tailscale**.

### Tailscale Network (`kylebrooks.20to20@`)

| Hostname        | Tailscale IP   | OS      |
|-----------------|----------------|---------|
| kylesdesktop    | 100.94.151.80  | Windows |
| desktop-265dqfr | 100.122.223.46 | Windows |
| code-server     | 100.94.22.122  | Linux   |
| marceline       | 100.73.117.27  | Linux   |
| proxmox         | 100.78.68.64   | Linux   |

---

## SSH Access

OpenSSH Server is installed and running on RADIO PC.

**Connect:**
```powershell
ssh "RADIO PC@100.122.223.46"
```

**Notes:**
- Auth: password-based
- Username contains a space — must be quoted
- SSH host key fingerprint: `SHA256:pwnG4oiMTEWWl4hWUXs0P6oCJ7J6ZbQHZA+6Y8mL2dg`

### Recommended: Set up SSH key auth
To avoid password prompts on future connections, copy your public key to the target:
```powershell
# On dev machine — append your public key to the target's authorized_keys
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh "RADIO PC@100.122.223.46" "mkdir C:\Users\RADIO` PC\.ssh 2>nul & type >> C:\Users\RADIO` PC\.ssh\authorized_keys"
```

---

## Setup History

| Date       | Action                                      |
|------------|---------------------------------------------|
| 2026-04-23 | Installed OpenSSH Server on RADIO PC        |
| 2026-04-23 | Installed Tailscale on RADIO PC             |
| 2026-04-23 | Confirmed SSH connectivity via Tailscale    |
