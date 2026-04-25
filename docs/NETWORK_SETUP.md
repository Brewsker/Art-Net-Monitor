# Network Setup — UniFi Port Mirroring

## Overview

This system uses **port mirroring (SPAN)** to passively capture Art-Net traffic.
The ThinkCentre (RADIO PC) receives a copy of all traffic from the configured source ports
on the UniFi switch. It does **not** participate in the network as an active device on the lighting VLAN.

---

## IMPORTANT — Passive Monitoring Only

- This system is **NOT inline** with lighting traffic
- This system **does not transmit** Art-Net or sACN
- Failure of this system has **zero impact** on lighting operations
- The capture NIC should have **no IP address** on the lighting subnet (optional but recommended)

---

## UniFi Port Mirror Configuration

### Mirror Source Ports (traffic to copy)

| Source | Description                  |
|--------|------------------------------|
| Port X | Lighting controller uplink   |
| Port Y | Elation node 1               |
| Port Z | Elation node 2               |

> **TODO:** Replace Port X/Y/Z with actual UniFi switch port numbers once confirmed on-site.

### Mirror Destination Port

| Destination | Description                          |
|-------------|--------------------------------------|
| Port N      | ThinkCentre (RADIO PC) capture NIC   |

> **TODO:** Replace Port N with actual switch port connected to RADIO PC's capture NIC.

---

## UniFi Switch Configuration Steps

1. Log in to UniFi Network Controller
2. Navigate to: **Devices → [Switch] → Ports**
3. Select the destination port (connected to RADIO PC)
4. Enable **Port Mirroring**
5. Set **Mirror Source**: select all source ports listed above
6. Apply and confirm traffic is visible in Wireshark

---

## RADIO PC Network Interfaces

As of initial setup:

| Adapter Name | Description                           | Status |
|--------------|---------------------------------------|--------|
| Ethernet     | Realtek Gaming 2.5GbE Family Controller | Up   |
| Tailscale    | Tailscale Tunnel (management)         | Up     |

> **Note:** Currently only one physical NIC is visible. If a dedicated capture NIC is added,
> it should receive the SPAN port traffic. The Tailscale interface is used for remote management
> and should NOT be used for capture.

---

## NIC Power Saving — Recommended Disable Steps

To prevent the capture NIC from dropping packets due to power management:

1. Open **Device Manager**
2. Expand **Network Adapters**
3. Right-click the capture NIC → **Properties**
4. Go to **Power Management** tab
5. Uncheck: *Allow the computer to turn off this device to save power*
6. Click OK

> This change is per-device and reversible at any time.

---

## Do NOT

- Do NOT bridge the Tailscale interface with the capture NIC
- Do NOT assign the capture NIC an IP on the lighting subnet (unless explicitly required)
- Do NOT modify UniFi ACLs or VLANs without documenting the change
