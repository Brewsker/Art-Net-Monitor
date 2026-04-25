# list-interfaces.ps1
# Lists all network interfaces visible to tshark/Npcap.
# Run this first to identify the interface index for your capture NIC.
#
# Usage:
#   .\list-interfaces.ps1

$tshark = "C:\Program Files\Wireshark\tshark.exe"

if (-not (Test-Path $tshark)) {
    Write-Error "tshark not found at: $tshark"
    Write-Host "Make sure Wireshark is installed with tshark."
    exit 1
}

Write-Host ""
Write-Host "=== Available Capture Interfaces ===" -ForegroundColor Cyan
Write-Host "The number on the LEFT is the InterfaceId to use with other scripts." -ForegroundColor Gray
Write-Host ""

# Run tshark -D and annotate each line
$lines = & $tshark -D 2>&1
foreach ($line in $lines) {
    $lower = $line.ToLower()

    # Determine annotation and color
    if ($lower -match 'loopback') {
        $tag   = "  [LOOPBACK - use for self-test with artnet-generator]"
        $color = "DarkYellow"
    } elseif ($lower -match 'tailscale') {
        $tag   = "  [TAILSCALE - management tunnel, do not capture here]"
        $color = "DarkGray"
    } elseif ($lower -match 'bluetooth') {
        $tag   = "  [BLUETOOTH - ignore]"
        $color = "DarkGray"
    } elseif ($lower -match 'wi-fi' -or $lower -match 'wifi' -or $lower -match 'wireless') {
        $tag   = "  [WI-FI]"
        $color = "DarkGray"
    } elseif ($lower -match 'local area connection\*' -or $lower -match 'vethernet' -or $lower -match 'hyper-v') {
        $tag   = "  [VIRTUAL - ignore]"
        $color = "DarkGray"
    } elseif ($lower -match 'etw') {
        $tag   = "  [ETW - ignore]"
        $color = "DarkGray"
    } elseif ($lower -match 'ethernet 2' -or $lower -match 'ethernet2') {
        $tag   = "  [ETHERNET 2 - USB-A NIC / secondary capture]"
        $color = "Green"
    } elseif ($lower -match 'ethernet') {
        $tag   = "  [ETHERNET - primary physical NIC / SPAN capture]"
        $color = "Green"
    } else {
        $tag   = ""
        $color = "White"
    }

    Write-Host "$line$tag" -ForegroundColor $color
}

Write-Host ""
Write-Host "RECOMMENDED INTERFACE IDs:" -ForegroundColor Yellow
Write-Host "  Ethernet (Realtek)  -> SPAN / real network capture" -ForegroundColor Green
Write-Host "  Ethernet 2 (USB-A)  -> secondary / dedicated capture NIC" -ForegroundColor Green
Write-Host "  Loopback            -> self-test with Art-Net Generator (shortcut 6)" -ForegroundColor DarkYellow
Write-Host "  Tailscale           -> management only, do NOT capture here" -ForegroundColor DarkGray
Write-Host ""
