# artnet-alerts.ps1
# View the Art-Net alert log. Reads log path from config.json if present.
#
# Usage:
#   .\artnet-alerts.ps1               # Show last 50 entries
#   .\artnet-alerts.ps1 -Lines 100    # Show last 100 entries
#   .\artnet-alerts.ps1 -Follow       # Tail the log live (like tail -f)

param(
    [int]$Lines = 50,
    [switch]$Follow,
    [string]$LogPath = ""
)

# Resolve log path from config.json if not specified
if ($LogPath -eq "") {
    $configPath = "C:\AV-Monitoring\config.json"
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.paths.alerts_log) { $LogPath = $cfg.paths.alerts_log }
        } catch {}
    }
    if ($LogPath -eq "") { $LogPath = "C:\AV-Monitoring\logs\alerts.log" }
}

if (-not (Test-Path $LogPath)) {
    Write-Host ""
    Write-Host "No alerts log found at: $LogPath" -ForegroundColor Yellow
    Write-Host "Start monitoring with:  .\start-universe-monitor.ps1" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

function Show-LogEntry([string]$entry) {
    if     ($entry -match '^\[ALERT\]')    { Write-Host $entry -ForegroundColor Red }
    elseif ($entry -match '^\[RECOVERY\]') { Write-Host $entry -ForegroundColor Green }
    elseif ($entry -match '^\[WARN\]')     { Write-Host $entry -ForegroundColor Yellow }
    elseif ($entry -match '^\[INFO\]')     { Write-Host $entry -ForegroundColor Cyan }
    else                                   { Write-Host $entry -ForegroundColor Gray }
}

Write-Host ""
if ($Follow) {
    Write-Host "Following: $LogPath  (Ctrl+C to stop)" -ForegroundColor Cyan
    Write-Host ""
    # Show recent history first, then follow new lines
    Get-Content $LogPath -Tail $Lines | ForEach-Object { Show-LogEntry $_ }
    Get-Content $LogPath -Wait | ForEach-Object { Show-LogEntry $_ }
} else {
    Write-Host "=== Last $Lines entries: $LogPath ===" -ForegroundColor Cyan
    Write-Host ""
    Get-Content $LogPath -Tail $Lines | ForEach-Object { Show-LogEntry $_ }
    Write-Host ""
}
