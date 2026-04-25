# Proposed Feature: Infrastructure & Reliability

## 1. Windows Task Scheduler Auto-Start

Register a Scheduled Task on RADIO PC so the monitor launches automatically at logon or system start,
without requiring the operator to manually open the GUI.

- New script: `scripts\register-task.ps1`
- Creates a Task Scheduler entry via `Register-ScheduledTask` (PowerShell cmdlet, no COM needed)
- Trigger: at logon of current user (or at system start for always-on headless mode)
- Action: launch `artnet-monitor-gui.ps1` hidden (no console window)
- Run As: current user with highest privileges
- Add a corresponding "Unregister Task" option to `create-shortcuts.ps1` or a new removal script

---

## 2. tshark Watchdog / Auto-Restart

The monitor loop exits if tshark's stdout closes — caused by tshark crash, NIC driver reset,
Npcap driver fault, or Windows update restarting services.

- A thin wrapper script (`scripts\watchdog.ps1`) that:
  1. Launches `monitor-universes.ps1` as a child process
  2. Waits for exit
  3. Logs the restart event to `alerts.log`
  4. Waits a configurable delay (default 10s) then relaunches
- The Scheduled Task (see above) points to the watchdog, not the monitor directly
- Config key: `watchdog.restart_delay_seconds`, `watchdog.max_restarts` (0 = unlimited)

---

## 3. Multi-Interface Support

Currently locked to one tshark capture interface. Larger topologies may need simultaneous monitoring
on two NICs — e.g., the capture NIC and a second show network segment.

- Extend `config.json` to accept `capture.interface_ids` as an array instead of a single `interface_id`
- Launch one tshark process per interface; merge stdout streams into the same parsing loop
  via multiple `ReadLineAsync` tasks
- Universe namespace stays flat — source IPs disambiguate which segment traffic came from
- GUI interface selector becomes a multi-select checklist
