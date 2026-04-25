# register-task.ps1
# Creates (or removes) a Windows Task Scheduler entry so the Art-Net Monitor GUI
# launches automatically at logon, without the operator touching anything.
#
# Run once as Administrator (required to register tasks that request
# highest-privilege execution):
#
#   .\register-task.ps1              # install (at logon of current user)
#   .\register-task.ps1 -Remove      # uninstall
#   .\register-task.ps1 -WatchdogMode # point task at watchdog.ps1 instead of GUI
#
# The task runs the GUI (or watchdog) via a VBScript wrapper so no console window
# appears at launch.  The .lnk shortcuts created by create-shortcuts.ps1 are
# separate — this is the headless auto-start mechanism.

param(
    [switch]$Remove,
    [switch]$WatchdogMode,
    [string]$ScriptsDir = "C:\AV-Monitoring\scripts"
)

$TaskName = "Art-Net Monitor - Auto Start"

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Task '$TaskName' removed." -ForegroundColor Green
    } else {
        Write-Host "Task '$TaskName' not found — nothing to remove." -ForegroundColor Yellow
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
$psExe     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$targetPs1 = if ($WatchdogMode) {
    Join-Path $ScriptsDir "watchdog.ps1"
} else {
    Join-Path $ScriptsDir "artnet-monitor-gui.ps1"
}

if (-not (Test-Path $targetPs1)) {
    Write-Error "Target script not found: $targetPs1"
    exit 1
}

$action  = New-ScheduledTaskAction `
    -Execute  $psExe `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetPs1`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal `
    -UserId    "$env:USERDOMAIN\$env:USERNAME" `
    -RunLevel  Highest `
    -LogonType Interactive

try {
    # Remove any existing entry with this name first
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Description "Launches the Art-Net Universe Monitor GUI at user logon. Managed by register-task.ps1." | Out-Null

    $mode = if ($WatchdogMode) { "watchdog (watchdog.ps1)" } else { "GUI (artnet-monitor-gui.ps1)" }
    Write-Host ""
    Write-Host "Task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host "  Mode    : $mode" -ForegroundColor Gray
    Write-Host "  Trigger : at logon of $env:USERNAME" -ForegroundColor Gray
    Write-Host "  RunLevel: Highest (UAC elevated)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "The monitor will start automatically on next logon." -ForegroundColor Cyan
    Write-Host "To remove: .\register-task.ps1 -Remove" -ForegroundColor Gray
    Write-Host ""
} catch {
    Write-Error "Failed to register task: $($_.Exception.Message)"
    exit 1
}
