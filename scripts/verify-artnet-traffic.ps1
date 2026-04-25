# verify-artnet-traffic.ps1
# Listens for Art-Net traffic (UDP 6454) for a short window and reports what it sees.
# Use this to confirm the SPAN mirror is working and Art-Net packets are visible.
#
# Usage:
#   .\verify-artnet-traffic.ps1 -InterfaceId 1
#   .\verify-artnet-traffic.ps1 -InterfaceId 1 -DurationSeconds 60
#
# Run list-interfaces.ps1 first to find the correct InterfaceId.

param(
    [Parameter(Mandatory = $true)]
    [int]$InterfaceId,

    [int]$DurationSeconds = 30
)

$tshark = "C:\Program Files\Wireshark\tshark.exe"

if (-not (Test-Path $tshark)) {
    Write-Error "tshark not found at: $tshark"
    exit 1
}

Write-Host ""
Write-Host "=== Art-Net Traffic Verification ===" -ForegroundColor Cyan
Write-Host "Interface ID : $InterfaceId" -ForegroundColor Gray
Write-Host "Duration     : $DurationSeconds seconds" -ForegroundColor Gray
Write-Host "Filter       : udp port 6454" -ForegroundColor Gray
Write-Host ""
Write-Host "Listening... (press Ctrl+C to stop early)" -ForegroundColor Yellow
Write-Host ""

# Capture and display: frame number, timestamp, source IP, destination IP, packet length
& $tshark `
    -i $InterfaceId `
    -f "udp port 6454" `
    -a duration:$DurationSeconds `
    -T fields `
    -e frame.number `
    -e frame.time_relative `
    -e ip.src `
    -e ip.dst `
    -e frame.len `
    -E header=y `
    -E separator="`t" `
    -E quote=n

Write-Host ""
if ($LASTEXITCODE -eq 0) {
    Write-Host "=== Capture complete ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "If you saw packets above: SPAN mirror is working. Art-Net is visible." -ForegroundColor Green
    Write-Host "If no packets appeared  : Check UniFi SPAN config. See docs\TROUBLESHOOTING.md." -ForegroundColor Red
} else {
    Write-Host "tshark exited with error code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "Check that the interface ID is correct and Npcap is installed." -ForegroundColor Yellow
}
Write-Host ""
