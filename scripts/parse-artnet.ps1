# parse-artnet.ps1
# Diagnostic tool: captures Art-Net packets and prints structured output in real-time.
# Does NOT track universes or log alerts — use start-universe-monitor.ps1 for that.
#
# Useful for:
#   - Verifying the pipeline works
#   - Seeing which universes and source IPs are active
#   - Debugging before enabling full monitoring
#
# Usage:
#   .\parse-artnet.ps1 -InterfaceId 8
#   .\parse-artnet.ps1 -InterfaceId 10 -DurationSeconds 30
#
# Run list-interfaces.ps1 first to find your InterfaceId.
# Interface 10 = loopback (use with artnet-generator.ps1 for self-test).

param(
    [Parameter(Mandatory=$true)]
    [int]$InterfaceId,

    # 0 = run until Ctrl+C
    [int]$DurationSeconds = 0
)

$tshark = "C:\Program Files\Wireshark\tshark.exe"
if (-not (Test-Path $tshark)) { Write-Error "tshark not found at: $tshark"; exit 1 }

# ---------------------------------------------------------------------------
# Universe extraction from raw UDP payload hex
# Art-Net ArtDmx packet layout:
#   Bytes 0-7:   ID "Art-Net\0"
#   Bytes 8-9:   OpCode 0x00 0x50 (ArtDmx, little-endian)
#   Bytes 10-11: Protocol version
#   Byte  12:    Sequence
#   Byte  13:    Physical
#   Bytes 14-15: Universe (SubUni, Net — little-endian, 15-bit PortAddress)
# ---------------------------------------------------------------------------
function Get-ArtNetUniverse([string]$hexRaw) {
    $hex = $hexRaw -replace '[^0-9a-fA-F]', ''
    if ($hex.Length -lt 32) { return $null }
    if ($hex.Substring(0, 16).ToLower() -ne "4172742d4e657400") { return $null }
    try {
        if ([Convert]::ToByte($hex.Substring(16, 2), 16) -ne 0x00) { return $null }
        if ([Convert]::ToByte($hex.Substring(18, 2), 16) -ne 0x50) { return $null }
        $subUni = [Convert]::ToByte($hex.Substring(28, 2), 16)
        $net    = [Convert]::ToByte($hex.Substring(30, 2), 16)
        return (($net -band 0x7F) -shl 8) -bor $subUni
    } catch { return $null }
}

$tsharkArgs = @(
    "-i", $InterfaceId,
    "-f", "udp port 6454",
    "-s", "80",            # Capture only first 80 bytes (enough for Art-Net header)
    "-T", "fields",
    "-e", "frame.time_epoch",
    "-e", "ip.src",
    "-e", "artnet.artdmx.universe",   # Use Wireshark Art-Net dissector if available
    "-e", "udp.payload",              # Fallback: raw hex for manual parsing
    "-E", "separator=|",
    "-l"                   # Line-buffered output
)
if ($DurationSeconds -gt 0) { $tsharkArgs += @("-a", "duration:$DurationSeconds") }

Write-Host ""
Write-Host "=== Art-Net Packet Parser ===" -ForegroundColor Cyan
Write-Host "Interface : $InterfaceId  |  Filter: udp port 6454  |  Ctrl+C to stop" -ForegroundColor Gray
Write-Host ""
Write-Host "Timestamp         Source IP            Universe" -ForegroundColor DarkGray
Write-Host "-------------     ---------------      --------" -ForegroundColor DarkGray

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $tshark
$psi.Arguments              = $tsharkArgs -join " "
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true

$proc  = [System.Diagnostics.Process]::Start($psi)
$count = 0

try {
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts  = $line.Split('|')
        if ($parts.Count -lt 2) { continue }

        $epoch  = $parts[0].Trim()
        $srcIp  = $parts[1].Trim()
        $artUni = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
        $hexPay = if ($parts.Count -ge 4) { $parts[3].Trim() } else { "" }

        # Convert epoch to readable time
        $ts = $epoch
        if ($epoch -match '^\d+\.\d+$') {
            try {
                $ts = [DateTimeOffset]::FromUnixTimeMilliseconds(
                    [long]([double]$epoch * 1000)
                ).LocalDateTime.ToString("HH:mm:ss.fff")
            } catch {}
        }

        # Resolve universe: try dissector field first, then payload fallback
        $universe = $null
        if ($artUni -match '^\d+$') {
            $universe = [int]$artUni
        } elseif ($hexPay.Length -ge 32) {
            $universe = Get-ArtNetUniverse $hexPay
        }

        if ($null -ne $universe -and $srcIp -ne "") {
            $count++
            Write-Host ($ts.PadRight(18))  -NoNewline -ForegroundColor White
            Write-Host ($srcIp.PadRight(21)) -NoNewline -ForegroundColor Gray
            Write-Host "Universe $universe" -ForegroundColor Cyan
        }
    }
} finally {
    if (-not $proc.HasExited) { $proc.Kill() }
    Write-Host ""
    Write-Host "Parsed $count Art-Net packets." -ForegroundColor Gray
    Write-Host ""
}
