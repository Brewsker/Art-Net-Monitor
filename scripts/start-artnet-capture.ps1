# start-artnet-capture.ps1
# Starts a rotating ring-buffer capture of Art-Net (UDP 6454) traffic.
# Files are saved to C:\AV-Monitoring\captures\ in .pcapng format.
#
# Ring buffer behavior:
#   - Each file covers DurationSeconds seconds of traffic
#   - Once FileCount files exist, the oldest is overwritten
#   - Default: 48 x 300s = ~4 hours of rolling history
#
# Usage:
#   .\start-artnet-capture.ps1 -InterfaceId 1
#   .\start-artnet-capture.ps1 -InterfaceId 1 -DurationSeconds 600 -FileCount 24
#
# Run list-interfaces.ps1 first to find the correct InterfaceId.
# Open captured files in Wireshark or analyze with tshark.

param(
    [Parameter(Mandatory = $true)]
    [int]$InterfaceId,

    # How many seconds per capture file
    [int]$DurationSeconds = 300,

    # How many files to keep before wrapping (ring buffer)
    [int]$FileCount = 48,

    # Output file path (tshark appends a timestamp and index automatically)
    [string]$OutputPath = "C:\AV-Monitoring\captures\artnet_capture.pcapng"
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
Write-Host "=== Starting Art-Net Capture (Ring Buffer) ===" -ForegroundColor Cyan
Write-Host "Interface ID  : $InterfaceId" -ForegroundColor Gray
Write-Host "File duration : $DurationSeconds seconds" -ForegroundColor Gray
Write-Host "File count    : $FileCount (ring buffer)" -ForegroundColor Gray
Write-Host "Output path   : $OutputPath" -ForegroundColor Gray
Write-Host "Filter        : udp port 6454" -ForegroundColor Gray
Write-Host ""
Write-Host "Running... Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

& $tshark `
    -i $InterfaceId `
    -f "udp port 6454" `
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
