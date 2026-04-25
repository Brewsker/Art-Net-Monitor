# Proposed Feature: Generator Enhancements

## 1. Per-Channel Level Control

Currently all 512 channels in each universe are set to the same value (uniform fill or sine ramp).
A channel-value override table would allow parking specific fixtures at specific levels for node testing.

- Config key: `generator.channel_overrides` — array of `{ universe, channel, value }` objects
- Applied after the base DMX value is computed; overrides take precedence
- Useful for "universe 3, channel 1 = 255" to test a specific dimmer or fixture
- Editable from a simple text/JSON editor panel in the GUI generator section

---

## 2. Scene Stepping / Cue Playback

Load a CSV of DMX scenes and step through them on a timer or keypress, simulating a real show cue stack.

- CSV format: `universe, channel, value, duration_ms` (one row per channel change, grouped by cue number)
- Alternatively: a simple JSON array of scenes, each scene being a flat array of 512 channel values
- GUI controls: Load Scene File, Step Next Cue, Auto-Step (with configurable interval)
- Useful for verifying eNode response to full show sequences, not just steady-state traffic

---

## 3. Burst / Stress Mode

Send packets significantly above the 44 pkt/s Art-Net spec limit to deliberately trigger the rate-overload
detection in `monitor-universes.ps1` — useful for testing that the monitoring alerting works correctly.

- CLI flag: `-Burst` (or GUI checkbox "Stress Test Mode")
- Sends at configurable Hz (e.g., 100 pkt/s) for a defined duration
- Clearly labeled in output: `[STRESS TEST] Sending at 100 Hz — this WILL trigger overload alerts`
- Auto-stops after `DurationSeconds` to avoid leaving nodes in a faulted state
