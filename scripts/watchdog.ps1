# watchdog.ps1
# Thin wrapper that keeps monitor-universes.ps1 running continuously.
#
# If tshark crashes, the NIC resets, or the monitor exits for any reason,
# the watchdog logs the event and relaunches after a configurable delay.
# The Windows Scheduled Task (register-task.ps1 -WatchdogMode) points here.
#
# Usage:
#   .\watchdog.ps1
#   .\watchdog.ps1 -MaxRestarts 5    # stop after 5 restarts (0 = unlimited)
#   .\watchdog.ps1 -RestartDelay 30  # wait 30s between restarts
#
# Config keys (config.json, section "watchdog"):
#   restart_delay_seconds  (int,  default 10)
#   max_restarts           (int,  default 0 = unlimited)

param(
    [int]$RestartDelay = 0,
    [int]$MaxRestarts  = -1,    # -1 = use config / default
    [string]$ConfigPath = "C:\AV-Monitoring\config.json"
)

$ScriptsDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$MonitorScript = Join-Path $ScriptsDir "monitor-universes.ps1"
$AlertsLog   = "C:\AV-Monitoring\logs\alerts.log"
$LogsDir     = "C:\AV-Monitoring\logs"
$WdRestartDelaySecs = 10
$WdMaxRestarts      = 0   # 0 = unlimited

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.paths.logs)                          { $LogsDir     = $cfg.paths.logs }
        if ($cfg.paths.alerts_log)                    { $AlertsLog   = $cfg.paths.alerts_log }
        if ($cfg.watchdog.restart_delay_seconds)      { $WdRestartDelaySecs = [int]$cfg.watchdog.restart_delay_seconds }
        if ($null -ne $cfg.watchdog.max_restarts -and
            $cfg.watchdog.max_restarts -is [int])     { $WdMaxRestarts = [int]$cfg.watchdog.max_restarts }
    } catch {
        Write-Warning "Could not load $ConfigPath — using defaults."
    }
}

# CLI overrides
if ($RestartDelay -gt 0) { $WdRestartDelaySecs = $RestartDelay }
if ($MaxRestarts  -ge 0) { $WdMaxRestarts       = $MaxRestarts }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

function Write-WatchdogLog([string]$Msg) {
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[WATCHDOG] [$ts] $Msg"
    Write-Host $entry -ForegroundColor Magenta
    Add-Content -Path $AlertsLog -Value $entry
}

if (-not (Test-Path $MonitorScript)) {
    Write-Error "monitor-universes.ps1 not found at: $MonitorScript"
    exit 1
}

# ---------------------------------------------------------------------------
# Watchdog loop
# ---------------------------------------------------------------------------
$psExe      = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$restartNum = 0

Write-Host ""
Write-Host "==========================================" -ForegroundColor Magenta
Write-Host "   Art-Net Monitor Watchdog" -ForegroundColor Magenta
Write-Host "==========================================" -ForegroundColor Magenta
Write-Host "Monitor script : $MonitorScript" -ForegroundColor Gray
Write-Host "Restart delay  : ${WdRestartDelaySecs}s" -ForegroundColor Gray
Write-Host "Max restarts   : $(if($WdMaxRestarts -eq 0){'unlimited'}else{$WdMaxRestarts})" -ForegroundColor Gray
Write-Host "Log            : $AlertsLog" -ForegroundColor Gray
Write-Host ""

Write-WatchdogLog "Watchdog started. RestartDelay:${WdRestartDelaySecs}s  MaxRestarts:$(if($WdMaxRestarts -eq 0){'unlimited'}else{$WdMaxRestarts})"

while ($true) {
    $start = [DateTime]::Now
    Write-WatchdogLog "Launching monitor-universes.ps1 (restart #$restartNum)..."

    try {
        # Run monitor synchronously in this process's PowerShell; captures exit code
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $psExe
        $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -NonInteractive -File `"$MonitorScript`""
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError  = $false
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $false

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $proc.Dispose()
    } catch {
        $exitCode = -1
        Write-WatchdogLog "Failed to launch monitor: $($_.Exception.Message)"
    }

    $uptime = [int]([DateTime]::Now - $start).TotalSeconds
    Write-WatchdogLog "Monitor exited (code:$exitCode  uptime:${uptime}s)"

    $restartNum++

    if ($WdMaxRestarts -gt 0 -and $restartNum -gt $WdMaxRestarts) {
        Write-WatchdogLog "Max restarts ($WdMaxRestarts) reached — watchdog stopping."
        break
    }

    Write-WatchdogLog "Waiting ${WdRestartDelaySecs}s before restart $restartNum..."
    $deadline = [DateTime]::Now.AddSeconds($WdRestartDelaySecs)
    while ([DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
}

Write-WatchdogLog "Watchdog stopped."
