# start-sacn-capture.ps1
# Starts a rotating ring-buffer capture of sACN (E1.31) traffic on UDP port 5568.
# Same behavior as start-artnet-capture.ps1 but for sACN.
#
# sACN uses multicast addresses in the range 239.255.x.x
# Your NIC may need to join those multicast groups to receive sACN traffic.
#
# Usage:
#   .\start-sacn-capture.ps1 -InterfaceId 1
#   .\start-sacn-capture.ps1 -InterfaceId 1 -DurationSeconds 600 -FileCount 24
#
# Run list-interfaces.ps1 first to find the correct InterfaceId.

param(
    [Parameter(Mandatory = $true)]
    [int]$InterfaceId,

    # How many seconds per capture file
    [int]$DurationSeconds = 300,

    # How many files to keep before wrapping (ring buffer)
    [int]$FileCount = 48,

    # Output file path (tshark appends a timestamp and index automatically)
    [string]$OutputPath = "C:\AV-Monitoring\captures\sacn_capture.pcapng"
)

$tshark = "C:\Program Files\Wireshark\tshark.exe"

if (-not (Test-Path $tshark)) {
    Write-Error "tshark not found at: $tshark"
    exit 1
}

# Ensure output directory exists
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

Write-Host ""
Write-Host "=== Starting sACN Capture (Ring Buffer) ===" -ForegroundColor Cyan
Write-Host "Interface ID  : $InterfaceId" -ForegroundColor Gray
Write-Host "File duration : $DurationSeconds seconds" -ForegroundColor Gray
Write-Host "File count    : $FileCount (ring buffer)" -ForegroundColor Gray
Write-Host "Output path   : $OutputPath" -ForegroundColor Gray
Write-Host "Filter        : udp port 5568" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: sACN is multicast. If no packets appear, verify your NIC" -ForegroundColor Yellow
Write-Host "      is receiving mirrored traffic and the switch forwards multicast." -ForegroundColor Yellow
Write-Host ""
Write-Host "Running... Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

& $tshark `
    -i $InterfaceId `
    -f "udp port 5568" `
    -b duration:$DurationSeconds `
    -b files:$FileCount `
    -w $OutputPath

Write-Host ""
if ($LASTEXITCODE -eq 0) {
    Write-Host "Capture stopped." -ForegroundColor Green
} else {
    Write-Host "tshark exited with error code: $LASTEXITCODE" -ForegroundColor Red
}
Write-Host "Files saved to: $outputDir" -ForegroundColor Gray
Write-Host ""
