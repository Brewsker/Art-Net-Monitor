# Proposed Feature: GUI Enhancements

## 1. Universe Health Grid Panel

Replace or supplement the scrolling log display with a **colored tile grid** — one tile per expected universe.

- Each tile shows: universe number, current state (OK / DROPPED / OVERLOAD / NEVER SEEN), and last-seen age
- Colors: green = OK, red = DROPPED, yellow = OVERLOAD/WARN, gray = never seen
- Updates on the existing GUI timer (same polling interval as the log refresher)
- Data source: a shared state file written by `monitor-universes.ps1` (e.g., `universe-status.json`)
  or read from the tail of `alerts.log`
- Far faster to assess 24+ universes at a glance than scanning log lines

Implementation note: WinForms `Panel` with dynamically created `Label` controls, one per universe,
sized and positioned in a grid layout. Color set via `BackColor`.

---

## 2. Per-Universe Packet Rate Gauge

Add a live Hz readout next to each universe in the health grid (or as a tooltip).

- The data is already computed in `$uniRateQ` inside `monitor-universes.ps1`
- Needs to be surfaced to the GUI via the shared status file
- Display as a numeric label (e.g., `~38 Hz`) with color coding: green < 40, yellow 40–44, red > 44

---

## 3. Alert Suppression Schedule

"Suppress alerts between HH:mm and HH:mm" — prevents false alarms during planned dark periods
(load-in with all fixtures off, intermission, etc.).

- Two time fields in the GUI (suppress-from, suppress-until)
- During the window, `Write-Alert` still logs to file but does NOT send email and does NOT sound audio
- Config keys: `monitoring.suppress_start`, `monitoring.suppress_end` (24h "HH:mm" strings)
- Stored in `config.json` and editable from the GUI Configuration section
