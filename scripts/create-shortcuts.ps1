# create-shortcuts.ps1
# Creates desktop shortcuts on this machine for all AV-Monitoring scripts.
# Run this once on RADIO PC (as Administrator for best results).
#
# Usage:
#   .\create-shortcuts.ps1

$scriptsPath = "C:\AV-Monitoring\scripts"
$shell = New-Object -ComObject WScript.Shell
$desktop = "$($shell.SpecialFolders('Desktop'))\Art-Net Sniffer"
if (-not (Test-Path $desktop)) { New-Item -ItemType Directory -Path $desktop | Out-Null }

function New-ScriptShortcut {
    param(
        [string]$Name,
        [string]$Script,
        [string]$Arguments = "",
        [switch]$NoExit,
        [switch]$Hidden
    )

    $lnkPath = "$desktop\$Name.lnk"
    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath = "powershell.exe"

    $flags = "-NoProfile -ExecutionPolicy Bypass"
    if ($NoExit)  { $flags += " -NoExit" }
    if ($Hidden)  { $flags += " -WindowStyle Hidden" }

    $fileArg = "-File `"$scriptsPath\$Script`""
    if ($Arguments) {
        $sc.Arguments = "$flags $fileArg $Arguments"
    } else {
        $sc.Arguments = "$flags $fileArg"
    }

    $sc.WorkingDirectory = $scriptsPath
    $sc.IconLocation = "powershell.exe,0"
    $sc.Description = "AV Monitoring: $Name"
    $sc.Save()

    # Set "Run as Administrator" flag (byte 0x15, bit 5 in the .lnk file)
    $bytes = [System.IO.File]::ReadAllBytes($lnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($lnkPath, $bytes)

    Write-Host "  Created: $Name.lnk" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Creating AV Monitoring Desktop Shortcuts ===" -ForegroundColor Cyan
Write-Host "Desktop: $desktop" -ForegroundColor Gray
Write-Host ""

# list-interfaces — no params, keep window open to read output
New-ScriptShortcut -Name "AV - 1. List Interfaces" `
    -Script "list-interfaces.ps1" `
    -NoExit

# verify-artnet-traffic — mandatory InterfaceId, PS will prompt; keep window open
New-ScriptShortcut -Name "AV - 2. Verify Art-Net Traffic" `
    -Script "verify-artnet-traffic.ps1" `
    -NoExit

# start-artnet-capture — runs until Ctrl+C, mandatory InterfaceId
New-ScriptShortcut -Name "AV - 3. Start Art-Net Capture" `
    -Script "start-artnet-capture.ps1"

# start-basic-artnet-log — runs until Ctrl+C, mandatory InterfaceId
New-ScriptShortcut -Name "AV - 4. Start Art-Net Log" `
    -Script "start-basic-artnet-log.ps1"

# start-sacn-capture — runs until Ctrl+C, mandatory InterfaceId
New-ScriptShortcut -Name "AV - 5. Start sACN Capture" `
    -Script "start-sacn-capture.ps1"

# artnet-generator — self-test: sends to localhost, capture on loopback (interface 10)
New-ScriptShortcut -Name "AV - 6. Art-Net Generator (loopback test)" `
    -Script "artnet-generator.ps1" `
    -Arguments "-DestinationIP 127.0.0.1 -DurationSeconds 0" `
    -NoExit

# start-universe-monitor — reads config.json, starts full monitoring engine
New-ScriptShortcut -Name "AV - 7. Start Universe Monitor" `
    -Script "start-universe-monitor.ps1" `
    -NoExit

# artnet-alerts — tail the alerts log live
New-ScriptShortcut -Name "AV - 8. View Alerts Log" `
    -Script "artnet-alerts.ps1" `
    -Arguments "-Follow" `
    -NoExit

# artnet-monitor-gui — Windows GUI control panel (wscript SW_HIDE = no console flash)
$lnkGui = "$desktop\AV - 9. Control Panel (GUI).lnk"
$scGui  = $shell.CreateShortcut($lnkGui)
$scGui.TargetPath      = "wscript.exe"
$scGui.Arguments       = "`"$scriptsPath\launch-gui.vbs`""
$scGui.WorkingDirectory = $scriptsPath
$scGui.IconLocation    = "powershell.exe,0"
$scGui.Description     = "AV Monitoring: Control Panel (GUI)"
$scGui.Save()
$bytesGui = [System.IO.File]::ReadAllBytes($lnkGui)
$bytesGui[0x15] = $bytesGui[0x15] -bor 0x20
[System.IO.File]::WriteAllBytes($lnkGui, $bytesGui)
Write-Host "  Created: AV - 9. Control Panel (GUI).lnk" -ForegroundColor Green

Write-Host ""
Write-Host "All shortcuts created on Desktop." -ForegroundColor Green
Write-Host ""
Write-Host "HOW TO USE:" -ForegroundColor Yellow
Write-Host "  1. Run 'AV - 1. List Interfaces' first" -ForegroundColor Gray
Write-Host "  2. Note the interface number for your Ethernet NIC" -ForegroundColor Gray
Write-Host "  3. Run any other shortcut - it will prompt: InterfaceId:" -ForegroundColor Gray
Write-Host "  4. Enter the interface number and press Enter" -ForegroundColor Gray
Write-Host ""
Write-Host "FOR UNIVERSE MONITORING (Phase 3):" -ForegroundColor Yellow
Write-Host "  1. Edit C:\AV-Monitoring\config.json - set interface_id and expected_universes" -ForegroundColor Gray
Write-Host "  2. Run shortcut 7 (Universe Monitor)" -ForegroundColor Gray
Write-Host "  3. Run shortcut 8 in a second window to watch alerts live" -ForegroundColor Gray
Write-Host ""
Write-Host "FOR LOOPBACK TEST (no SPAN required):" -ForegroundColor Yellow
Write-Host "  - Run shortcut 6 (generator) in one window" -ForegroundColor Gray
Write-Host "  - Run shortcut 2 (verify) and enter InterfaceId 10 (loopback)" -ForegroundColor Gray
Write-Host ""
