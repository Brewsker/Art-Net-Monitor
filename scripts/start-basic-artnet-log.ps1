# start-basic-artnet-log.ps1
# Captures Art-Net packets and logs timestamp + source IP to a text file.
# Useful for quick visibility without opening Wireshark.
# Appends to the log file if it already exists.
#
# Usage:
#   .\start-basic-artnet-log.ps1 -InterfaceId 1
#   .\start-basic-artnet-log.ps1 -InterfaceId 1 -DurationSeconds 120
#   .\start-basic-artnet-log.ps1 -InterfaceId 1 -LogPath C:\AV-Monitoring\logs\my_session.txt
#
# Run list-interfaces.ps1 first to find the correct InterfaceId.

param(
    [Parameter(Mandatory = $true)]
    [int]$InterfaceId,

    # How long to run (0 = run until Ctrl+C)
    [int]$DurationSeconds = 0,

    [string]$LogPath = "C:\AV-Monitoring\logs\artnet_log.txt"
)

$tshark = "C:\Program Files\Wireshark\tshark.exe"

if (-not (Test-Path $tshark)) {
    Write-Error "tshark not found at: $tshark"
    exit 1
}

# Ensure log directory exists
$logDir = Split-Path $LogPath
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# Build tshark arguments
$tsharkArgs = @(
    "-i", $InterfaceId,
    "-f", "udp port 6454",
    "-T", "fields",
    "-e", "frame.time",
    "-e", "ip.src",
    "-e", "ip.dst",
    "-e", "frame.len",
    "-E", "header=n",
    "-E", "separator=|",
    "-E", "quote=n",
    "-l"   # line-buffered output so we can tee in real time
)

if ($DurationSeconds -gt 0) {
    $tsharkArgs += @("-a", "duration:$DurationSeconds")
}

Write-Host ""
Write-Host "=== Art-Net Basic Log Mode ===" -ForegroundColor Cyan
Write-Host "Interface ID : $InterfaceId" -ForegroundColor Gray
Write-Host "Log file     : $LogPath" -ForegroundColor Gray
if ($DurationSeconds -gt 0) {
    Write-Host "Duration     : $DurationSeconds seconds" -ForegroundColor Gray
} else {
    Write-Host "Duration     : until Ctrl+C" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Running... (output shown here AND written to log file)" -ForegroundColor Yellow
Write-Host ""

# Write a session header to the log
$sessionHeader = "=== Session started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Add-Content -Path $LogPath -Value $sessionHeader
Write-Host $sessionHeader -ForegroundColor DarkGray

# Run tshark and tee output to console + log file
# Format: timestamp | src IP | dst IP | length
& $tshark @tsharkArgs | ForEach-Object {
    $line = $_
    # Parse fields (pipe-separated)
    $parts = $line -split '\|'
    if ($parts.Count -ge 3) {
        $ts  = $parts[0].Trim()
        $src = $parts[1].Trim()
        $dst = $parts[2].Trim()
        $len = if ($parts.Count -ge 4) { $parts[3].Trim() } else { "?" }
        $formatted = "$ts  src=$src  dst=$dst  len=$len"
        Write-Host $formatted
        Add-Content -Path $LogPath -Value $formatted
    } else {
        # Pass through any unformatted lines (e.g. errors)
        Write-Host $line
        Add-Content -Path $LogPath -Value $line
    }
}

$sessionFooter = "=== Session ended:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Add-Content -Path $LogPath -Value $sessionFooter
Write-Host ""
Write-Host $sessionFooter -ForegroundColor DarkGray
Write-Host "Log saved to: $LogPath" -ForegroundColor Green
Write-Host ""
