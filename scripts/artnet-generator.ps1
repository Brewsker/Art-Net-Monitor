# artnet-generator.ps1
# Sends Art-Net ArtDmx packets (UDP 6454) for pipeline testing.
# Supports multiple universes simultaneously with per-universe enable/disable.
#
# Usage:
#   .\artnet-generator.ps1
#   .\artnet-generator.ps1 -Universes 1,2,3,4 -DestinationIP 255.255.255.255
#   .\artnet-generator.ps1 -UniverseCount 24 -StartUniverse 1
#   .\artnet-generator.ps1 -EnabledUniverses 1,2,5 -UniverseCount 8
#   .\artnet-generator.ps1 -SourceIP 192.168.50.1 -DestinationIP 255.255.255.255 -DurationSeconds 0
#
# Art-Net spec: https://art-net.org.uk/structure/streaming-packets/artdmx-packet-definition/

param(
    [int[]]$Universes        = @(),
    [int]$UniverseCount      = 0,
    [int]$StartUniverse      = 1,
    [int[]]$EnabledUniverses = @(),
    [string]$DestinationIP   = "255.255.255.255",
    [string]$SourceIP        = "",
    [int]$PacketsPerSecond   = 10,
    [int]$DurationSeconds    = 60,
    [switch]$Ramp,
    [string]$ConfigPath      = "C:\AV-Monitoring\config.json"
)

if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.generator) {
            if ($DestinationIP -eq "255.255.255.255" -and $cfg.generator.destination_ip) { $DestinationIP = $cfg.generator.destination_ip }
            if (-not $SourceIP -and $cfg.generator.source_ip) { $SourceIP = $cfg.generator.source_ip }
            if ($UniverseCount -eq 0 -and $cfg.generator.universe_count) { $UniverseCount = [int]$cfg.generator.universe_count }
            if ($StartUniverse -eq 1 -and $cfg.generator.start_universe) { $StartUniverse = [int]$cfg.generator.start_universe }
            if ($EnabledUniverses.Count -eq 0 -and $cfg.generator.enabled_universes -and $cfg.generator.enabled_universes.Count -gt 0) { $EnabledUniverses = [int[]]$cfg.generator.enabled_universes }
            if ($PacketsPerSecond -eq 10 -and $cfg.generator.packets_per_second) { $PacketsPerSecond = [int]$cfg.generator.packets_per_second }
        }
    } catch {}
}

if ($Universes.Count -gt 0) { $allUniverses = $Universes }
elseif ($UniverseCount -gt 0) { $allUniverses = @($StartUniverse..($StartUniverse + $UniverseCount - 1)) }
else { $allUniverses = @(1) }

if ($EnabledUniverses.Count -gt 0) { $activeUniverses = @($allUniverses | Where-Object { $EnabledUniverses -contains $_ }) }
else { $activeUniverses = $allUniverses }

if ($activeUniverses.Count -eq 0) { Write-Warning "No universes enabled."; exit 0 }

$artNetId     = [System.Text.Encoding]::ASCII.GetBytes("Art-Net") + [byte[]](0x00)
$opCode       = [byte[]](0x00, 0x50)
$protVer      = [byte[]](0x00, 0x0E)
$seq          = [byte[]](0x00)
$physical     = [byte[]](0x00)
$dmxLen       = [byte[]](0x02, 0x00)
$headerPrefix = $artNetId + $opCode + $protVer + $seq + $physical

$udpClient = New-Object System.Net.Sockets.UdpClient
$udpClient.EnableBroadcast = $true
$udpClient.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,[System.Net.Sockets.SocketOptionName]::ReuseAddress,$true)
$boundSourceIP = ""
if ($SourceIP -ne "") {
    # --- Pre-validate: confirm IP is assigned to a live local adapter before binding ---
    $nics       = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
    $nicName    = $null
    $nicStatus  = $null
    foreach ($nic in $nics) {
        foreach ($addr in $nic.GetIPProperties().UnicastAddresses) {
            if ($addr.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                $addr.Address.ToString() -eq $SourceIP) {
                $nicName   = $nic.Name
                $nicStatus = $nic.OperationalStatus
                break
            }
        }
        if ($nicName) { break }
    }

    if ($null -eq $nicName) {
        Write-Warning "Source IP '$SourceIP' is NOT assigned to any local adapter."
        Write-Warning "Active IPv4 adapters on this machine:"
        foreach ($nic in $nics) {
            if ($nic.OperationalStatus -ne 'Up') { continue }
            foreach ($addr in $nic.GetIPProperties().UnicastAddresses) {
                if ($addr.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                    $addr.Address.ToString() -ne '127.0.0.1' -and
                    $addr.Address.ToString() -notmatch '^169\.254\.') {
                    Write-Warning "  $($nic.Name): $($addr.Address)"
                }
            }
        }
        Write-Warning "Continuing with OS default route. Fix Source IP in the GUI."
    } elseif ($nicStatus -ne 'Up') {
        Write-Warning "Source IP '$SourceIP' is on adapter '$nicName' but that adapter is $nicStatus."
        Write-Warning "Check the patch cable between Ethernet 2 and Ethernet 3."
        Write-Warning "Continuing with OS default route."
    } else {
        # IP is valid and adapter is Up - attempt bind
        try {
            $udpClient.Client.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($SourceIP), 0)))
            $boundSourceIP = $SourceIP
        } catch {
            Write-Warning "Bind failed for '$SourceIP' on '$nicName': $($_.Exception.Message)"
            Write-Warning "Continuing with OS default route."
        }
    }
}

$endpoint        = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($DestinationIP), 6454)
$intervalMs      = [int](1000 / $PacketsPerSecond)
$startTime       = [DateTime]::Now
$packetCount     = 0
$dmxValue        = [byte]0
$ControlFile     = Join-Path (Split-Path $ConfigPath -Parent) "generator-control.json"
$lastControlRead = [DateTime]::MinValue

Write-Host ""
Write-Host "=== Art-Net Generator ===" -ForegroundColor Cyan
Write-Host "Source NIC   : $(if ($boundSourceIP) { $boundSourceIP } elseif ($SourceIP) { "$SourceIP (bind failed - using OS default)" } else { '(OS default route)' })" -ForegroundColor Gray
Write-Host "Destination  : ${DestinationIP}:6454" -ForegroundColor Gray
Write-Host "Universes    : $($activeUniverses -join ', ')  ($($activeUniverses.Count) active of $($allUniverses.Count) total)" -ForegroundColor Green
Write-Host "Rate         : ~$PacketsPerSecond pkt/s per universe" -ForegroundColor Gray
if ($DurationSeconds -gt 0) { Write-Host "Duration     : $DurationSeconds seconds" -ForegroundColor Gray } else { Write-Host "Duration     : until Ctrl+C" -ForegroundColor Gray }
Write-Host ""
Write-Host "Sending... (Ctrl+C to stop)" -ForegroundColor Yellow
Write-Host ""

try {
    while ($true) {
        # Live universe control — read GUI control file every 500 ms
        if (([DateTime]::Now - $lastControlRead).TotalMilliseconds -ge 500) {
            if (Test-Path $ControlFile) {
                try {
                    $ctrl = Get-Content $ControlFile -Raw | ConvertFrom-Json
                    if ($null -ne $ctrl.enabled_universes) {
                        $newActive = [int[]]@($allUniverses | Where-Object { $ctrl.enabled_universes -contains $_ })
                        $newStr = ($newActive | Sort-Object) -join ','
                        $curStr = ($activeUniverses | Sort-Object) -join ','
                        if ($newStr -ne $curStr) {
                            $activeUniverses = $newActive
                            Write-Host "  [Live] Universes: $(if ($activeUniverses.Count) { $activeUniverses -join ', ' } else { '(none - paused)' }) ($($activeUniverses.Count) active)"
                        }
                    }
                } catch {}
            }
            $lastControlRead = [DateTime]::Now
        }

        if ($Ramp) { $dmxValue = [byte](($dmxValue + 1) -band 0xFF) }
        else { $dmxValue = [byte]([Math]::Abs([Math]::Sin($packetCount * 0.05)) * 200) }

        $dmxData = [byte[]]::new(512)
        for ($i = 0; $i -lt 512; $i++) { $dmxData[$i] = $dmxValue }

        $sendErrors = 0
        foreach ($uni in $activeUniverses) {
            $uniBytes = [byte[]]([byte]($uni -band 0xFF), [byte](($uni -shr 8) -band 0x7F))
            $packet   = $headerPrefix + $uniBytes + $dmxLen + $dmxData
            try {
                [void]$udpClient.Send($packet, $packet.Length, $endpoint)
                $packetCount++
            } catch {
                $sendErrors++
                if ($sendErrors -eq 1) {
                    Write-Host "  [WARN] UDP send error (U$uni): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
        $uniCount = if ($activeUniverses) { $activeUniverses.Count } else { 0 }
        $reportEvery = $PacketsPerSecond * $uniCount * 5
        if ($reportEvery -gt 0 -and $packetCount % $reportEvery -eq 0) {
            $rate = [Math]::Round($packetCount / [Math]::Max(1, $elapsed))
            Write-Host "  $([Math]::Round($elapsed,0))s | $packetCount pkts | ~$rate pkt/s | DMX $dmxValue"
        }

        if ($DurationSeconds -gt 0 -and $elapsed -ge $DurationSeconds) { break }
        Start-Sleep -Milliseconds $intervalMs
    }
} finally {
    $udpClient.Dispose()
    Write-Host ""
    Write-Host "Generator stopped. Sent $packetCount packets across $($activeUniverses.Count) universes." -ForegroundColor Green
    Write-Host ""
}
