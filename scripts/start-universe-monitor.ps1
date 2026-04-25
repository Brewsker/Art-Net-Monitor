# start-universe-monitor.ps1
# Launcher for the Art-Net universe monitor.
# Reads C:\AV-Monitoring\config.json and starts monitor-universes.ps1.
#
# This is the recommended entry point. Use the "AV - 7. Start Universe Monitor"
# desktop shortcut to run this, or call directly:
#
#   .\start-universe-monitor.ps1
#   .\start-universe-monitor.ps1 -InterfaceId 10              # loopback self-test
#   .\start-universe-monitor.ps1 -InterfaceId 8 -TimeoutSeconds 5

param(
    # Override interface_id from config.json
    [int]$InterfaceId    = 0,

    # Override timeout_seconds from config.json
    [int]$TimeoutSeconds = 0,

    [string]$ConfigPath  = "C:\AV-Monitoring\config.json"
)

$monitorScript = "C:\AV-Monitoring\scripts\monitor-universes.ps1"

if (-not (Test-Path $monitorScript)) {
    Write-Error "Monitor script not found: $monitorScript"
    Write-Host "Ensure files are deployed to C:\AV-Monitoring\scripts\" -ForegroundColor Yellow
    exit 1
}

$passThrough = @{ ConfigPath = $ConfigPath }
if ($InterfaceId    -gt 0) { $passThrough.InterfaceId    = $InterfaceId }
if ($TimeoutSeconds -gt 0) { $passThrough.TimeoutSeconds = $TimeoutSeconds }

& $monitorScript @passThrough
