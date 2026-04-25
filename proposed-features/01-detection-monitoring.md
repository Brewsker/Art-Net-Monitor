# Proposed Feature: Detection & Monitoring Enhancements

## 1. Sequence Number Discontinuity Tracking

Art-Net ArtDmx packets include a sequence byte (already parsed from the hex payload in `monitor-universes.ps1`).
Tracking jumps or resets would give a true **packet-loss metric** — useful for diagnosing bad switches or cable
faults that don't cause a full universe drop.

- Track `seq` byte per universe; alert when delta > 1 (skipped packets) or == 0 resets unexpectedly
- Log as `[WARN] Universe X sequence gap: expected Y got Z`
- No new tshark fields needed — `udp.payload` is already captured

---

## 2. Universe Source IP Change (Hijack) Detection

Currently duplicate sources are flagged, but if the *primary* source for a universe silently changes IP
mid-show (e.g., a backup node takes over unintentionally), that isn't specifically caught.

- Track "established primary" per universe (first IP seen after startup grace)
- Alert `[WARN]` if mid-session a *different* IP becomes the dominant sender
- Distinct from the existing duplicate-source warning — this is about silent takeovers

---

## 3. Node Reboot Fingerprinting

If a known source IP disappears for under ~30 seconds and then reappears, that pattern indicates a
**node power-cycle or NIC reset** rather than a true drop.

- Distinguish "controller crashed and recovered" vs "switch port bounced" vs "true signal loss"
- Track per-IP last-seen timestamps; compare against per-universe ALERT/RECOVERY timestamps
- Log as `[INFO] Universe X source 192.168.x.x rebooted (gap: Xs)` vs standard ALERT flow

---

## 4. Inter-Packet Jitter Per Universe

Track variance in packet arrival intervals. High jitter on a normally steady universe (e.g., σ > 5ms at 44 Hz)
indicates **network congestion** before it causes visible faults on nodes.

- Maintain a rolling window of arrival timestamps per universe (similar to `$uniRateQ`)
- Compute standard deviation of inter-packet gap
- Alert `[WARN]` when jitter exceeds configurable threshold (e.g., 5ms)
- Config key: `monitoring.jitter_warn_ms`
