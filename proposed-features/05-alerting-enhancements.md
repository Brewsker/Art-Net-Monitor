# Proposed Feature: Alerting Enhancements

## 1. Webhook / HTTP Push via ntfy.sh

Send push notifications to a phone app via a single HTTP POST to `ntfy.sh/<topic>`.
Free, no account required, works without SMTP configuration.

- Uses `[System.Net.WebClient]` or `Invoke-WebRequest` — no external dependencies
- Config keys: `alerts.ntfy_enabled` (bool), `alerts.ntfy_topic` (string), `alerts.ntfy_server`
  (default `https://ntfy.sh` — can point to a self-hosted ntfy instance)
- Alert priority: ALERT = urgent (5), WARN = default (3), RECOVERY = low (2)
- Add a "Test Notification" button in the GUI alongside the existing "Test Email" button
- Example POST:
  ```
  POST https://ntfy.sh/my-artnet-monitor
  Headers: Title: Art-Net ALERT, Priority: urgent, Tags: warning
  Body: Universe 3 missing for >2s (last seen: 21:34:11)
  ```

---

## 2. Local Audio Alarm

Play an audio alert when an ALERT fires — useful in loud environments where email/push may be missed.

- `[System.Media.SoundPlayer]` for a WAV file, or `[console]::Beep(freq, ms)` as a fallback
- Optional: place a `alert.wav` in `C:\AV-Monitoring\` for custom sounds
- Config key: `alerts.audio_enabled` (bool), `alerts.audio_file` (path, empty = use beep)
- Suppressed during the alert suppression schedule window (see GUI enhancements doc)
- RECOVERY plays a different tone (lower frequency / different WAV)
