# Proposed Feature: Logging & Reporting Enhancements

## 1. Log Rotation

`alerts.log` currently grows forever. Long-running deployments (overnight, multi-day shows) will produce
large files that become slow to read and tail.

- On each monitor start, check file size; if > configurable max (default 5 MB), rename to `alerts.log.1`
- Keep up to N rotated files (e.g., 3); delete oldest when exceeded
- Config keys: `logging.max_size_mb`, `logging.keep_count`
- Minimal code change — add a `Rotate-AlertsLog` call at startup in `monitor-universes.ps1`

---

## 2. Session Summary Email

On clean stop (Ctrl+C caught via `try/finally`, or GUI Stop button), send one summary email containing:

- Total ALERT count, RECOVERY count
- Universes that never appeared during the session
- Any sustained rate-overload or sACN conflicts
- Session uptime and total packet count

Useful for overnight or multi-day runs where the operator isn't watching in real time.
Uses the existing `Send-AlertEmail` plumbing — just a new call with a formatted body on exit.

---

## 3. Triggered .pcap Capture on Alert

When an ALERT fires, immediately launch a short tshark capture (5–10 seconds) and save a timestamped
`.pcap` file to `C:\AV-Monitoring\captures\`.

- Filename format: `alert_U{universe}_{timestamp}.pcap`
- Provides raw post-event evidence for post-show analysis in Wireshark
- Runs as a background `[System.Diagnostics.Process]` so it doesn't block the monitoring loop
- Config key: `logging.capture_on_alert` (bool), `logging.capture_duration_seconds`
