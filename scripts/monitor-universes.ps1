# monitor-universes.ps1
# Core Art-Net universe monitoring engine.
# Captures live traffic, tracks per-universe state, and logs timestamped alerts.
#
# Reads configuration from C:\AV-Monitoring\config.json
# Edit config.json to set your interface_id and expected_universes before running.
#
# Usage:
#   .\monitor-universes.ps1
#   .\monitor-universes.ps1 -InterfaceId 8
#   .\monitor-universes.ps1 -InterfaceId 8 -TimeoutSeconds 5
#
# Detects:
#   - Universe drop: no packet received within timeout_seconds
#   - Universe recovery: traffic resumes after a drop
#   - Duplicate sources: more than one IP sending the same universe
#   - Universe first seen: logs when a new universe appears
#   - Packet rate overload: per-universe Hz above Art-Net spec limit (>44 pkt/s)
#     eNode buffers overflow and may halt DMX output
#   - sACN (E1.31) competition: sACN traffic for a monitored universe detected
#     eNode auto-detection may switch protocol and silently drop Art-Net output
#   - Art-Net control packets: ArtAddress / ArtInput on the wire mid-show
#     These can reconfigure or disable eNode port directions live
#   - ARP IP conflict: another device is claiming a node's IP address
#     Node loses network access; all universes on that node disappear
#   - Sequence discontinuity: skipped or repeated ArtDmx sequence numbers indicate packet loss
#   - Source IP hijack: primary sender for a universe silently changes IP mid-show
#   - Node reboot: short-gap same-IP recovery fingerprinted as power-cycle vs true drop
#   - Jitter: high stddev in inter-packet arrival times signals upstream network congestion

param(
    # Override interface from config.json (single interface, backward-compat)
    [int]$InterfaceId    = 0,

    # Override timeout from config.json
    [int]$TimeoutSeconds = 0,

    [string]$ConfigPath  = "C:\AV-Monitoring\config.json"
)

# ---------------------------------------------------------------------------
# Defaults (overridden by config.json then by parameters)
# ---------------------------------------------------------------------------
$tsharkPath       = "C:\Program Files\Wireshark\tshark.exe"
$alertsLog        = "C:\AV-Monitoring\logs\alerts.log"
$logsDir          = "C:\AV-Monitoring\logs"
$captureInterface = 8
$captureInterfaces = @()   # multi-interface: set via capture.interface_ids array in config
$captureFilter    = "udp port 6454"
$timeoutSecs      = 2
$expectedUnis     = @(0, 1, 2, 3)
$warnDuplicate    = $true
$checkIntervalMs  = 500
$startupGrace     = 5    # seconds before alerting on never-seen expected universes
$statusInterval   = 30   # seconds between periodic status summaries
$rateWarnHz       = 44   # Art-Net spec max pkt/s per universe (node buffer fault threshold)
$jitterWarnMs     = 5    # stddev threshold (ms) for inter-packet jitter alert
$detectSACN       = $true  # warn if sACN appears for a monitored universe (eNode auto-switches)
$detectARPConflict = $true  # warn on ARP IP-MAC changes (node IP conflict = network blackout)
$warnArtCommand   = $true  # warn on ArtAddress/ArtInput packets that reconfigure node ports
$suppressStart    = ""    # "HH:mm" suppress alert emails from this time (24h); "" = disabled
$suppressEnd      = ""    # "HH:mm" suppress alert emails until this time (24h); "" = disabled
$logMaxSizeMB     = 5      # max alerts.log size in MB before rotation
$logKeepCount     = 3      # number of rotated log files to keep
$capturesDir      = "C:\AV-Monitoring\captures"  # directory for .pcap alert captures
$captureOnAlert   = $false # trigger a background tshark .pcap capture on each ALERT
$captureDurationSecs = 5   # duration of each triggered .pcap capture in seconds
$ntfyEnabled      = $false # send push notification via ntfy.sh on each alert
$ntfyTopic        = ""     # ntfy topic name (e.g. "my-artnet-monitor")
$ntfyServer       = "https://ntfy.sh"  # ntfy server (can be self-hosted)
$audioEnabled     = $false # play audio alert on ALERT events
$audioFile        = ""     # path to .wav file; empty = use Beep()

# ---------------------------------------------------------------------------
# Load config.json (single pass - monitoring + email settings)
# ---------------------------------------------------------------------------
if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.paths.tshark)                               { $tsharkPath       = $cfg.paths.tshark }
        if ($cfg.paths.alerts_log)                           { $alertsLog        = $cfg.paths.alerts_log }
        if ($cfg.paths.logs)                                 { $logsDir          = $cfg.paths.logs }
        if ($cfg.paths.captures)                             { $capturesDir      = $cfg.paths.captures }
        if ($cfg.capture.interface_id)                       { $captureInterface = [int]$cfg.capture.interface_id }
        # Multi-interface: interface_ids array overrides the scalar interface_id
        if ($cfg.capture.interface_ids -and $cfg.capture.interface_ids.Count -gt 0) {
            $captureInterfaces = @($cfg.capture.interface_ids | ForEach-Object { [int]$_ })
        }
        if ($cfg.capture.filter)                             { $captureFilter    = $cfg.capture.filter }
        if ($cfg.monitoring.timeout_seconds)                 { $timeoutSecs      = [int]$cfg.monitoring.timeout_seconds }
        if ($cfg.monitoring.expected_universes)              { $expectedUnis     = $cfg.monitoring.expected_universes }
        if ($null -ne $cfg.monitoring.duplicate_source_warn) { $warnDuplicate    = [bool]$cfg.monitoring.duplicate_source_warn }
        if ($cfg.monitoring.check_interval_ms)               { $checkIntervalMs  = [int]$cfg.monitoring.check_interval_ms }
        if ($cfg.monitoring.startup_grace_seconds)           { $startupGrace     = [int]$cfg.monitoring.startup_grace_seconds }
        if ($cfg.monitoring.rate_warn_hz)                    { $rateWarnHz       = [int]$cfg.monitoring.rate_warn_hz }
        if ($cfg.monitoring.jitter_warn_ms)                  { $jitterWarnMs     = [int]$cfg.monitoring.jitter_warn_ms }
        if ($null -ne $cfg.monitoring.detect_sacn)           { $detectSACN       = [bool]$cfg.monitoring.detect_sacn }
        if ($null -ne $cfg.monitoring.detect_arp_conflict)   { $detectARPConflict = [bool]$cfg.monitoring.detect_arp_conflict }
        if ($null -ne $cfg.monitoring.warn_art_command)      { $warnArtCommand   = [bool]$cfg.monitoring.warn_art_command }
        if ($cfg.logging.max_size_mb)                        { $logMaxSizeMB     = [int]$cfg.logging.max_size_mb }
        if ($cfg.logging.keep_count)                         { $logKeepCount     = [int]$cfg.logging.keep_count }
        if ($null -ne $cfg.logging.capture_on_alert)         { $captureOnAlert   = [bool]$cfg.logging.capture_on_alert }
        if ($cfg.logging.capture_duration_seconds)           { $captureDurationSecs = [int]$cfg.logging.capture_duration_seconds }
        if ($null -ne $cfg.alerts.ntfy_enabled)              { $ntfyEnabled   = [bool]$cfg.alerts.ntfy_enabled }
        if ($cfg.alerts.ntfy_topic)                          { $ntfyTopic     = $cfg.alerts.ntfy_topic }
        if ($cfg.alerts.ntfy_server)                         { $ntfyServer    = $cfg.alerts.ntfy_server }
        if ($null -ne $cfg.alerts.audio_enabled)             { $audioEnabled  = [bool]$cfg.alerts.audio_enabled }
        if ($cfg.alerts.audio_file)                          { $audioFile     = $cfg.alerts.audio_file }
        if ($cfg.monitoring.suppress_start) { $suppressStart = $cfg.monitoring.suppress_start }
        if ($cfg.monitoring.suppress_end)   { $suppressEnd   = $cfg.monitoring.suppress_end }
    } catch {
        Write-Warning "Could not fully load $ConfigPath : $_  -- Using defaults."
    }
} else {
    Write-Warning "config.json not found at $ConfigPath. Using defaults."
}

# Path for GUI health-grid status file (derived after config sets $logsDir)
$statusJsonPath = Join-Path $logsDir "universe-status.json"

# ---------------------------------------------------------------------------
# Email configuration (from config.json [email] section)
# Password is NOT stored globally - read from config only at send time
# ---------------------------------------------------------------------------
$emailEnabled    = $false
$smtpServer      = "smtp.gmail.com"
$smtpPort        = 587
$smtpUseSSL      = $true
$emailFrom       = ""
$emailTo         = ""
$emailAlertTypes = @("ALERT", "RECOVERY")

if (Test-Path $ConfigPath) {
    try {
        $emCfg = $cfg.email
        if ($emCfg) {
            if ($null -ne $emCfg.enabled)      { $emailEnabled    = [bool]$emCfg.enabled }
            if ($emCfg.smtp_server)            { $smtpServer      = $emCfg.smtp_server }
            if ($emCfg.smtp_port)              { $smtpPort        = [int]$emCfg.smtp_port }
            if ($null -ne $emCfg.use_ssl)      { $smtpUseSSL      = [bool]$emCfg.use_ssl }
            if ($emCfg.from_address)           { $emailFrom       = $emCfg.from_address }
            if ($emCfg.to_address)             { $emailTo         = $emCfg.to_address }
            if ($emCfg.alert_types)            { $emailAlertTypes = @($emCfg.alert_types) }
        }
    } catch {}
}

function Send-AlertEmail {
    param([string]$Type, [string]$Message)
    if (-not $emailEnabled)                          { return }
    if ($emailAlertTypes -notcontains $Type)         { return }
    if (-not $emailFrom -or -not $emailTo)           { return }
    # Read password from config at send time only - never kept in global scope
    $sendPass = ''
    try {
        $sendCfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($sendCfg.email.app_password) { $sendPass = $sendCfg.email.app_password }
    } catch {}
    if (-not $sendPass -or $sendPass -match '^xxxx')     { return }
    try {
        $subject = "[Art-Net Monitor] $Type on $(hostname)"
        $body    = "$Message`r`n`r`nTime: $(Get-Date)`r`nHost: $(hostname)"
        $smtp2 = New-Object System.Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtp2.EnableSsl = $smtpUseSSL
        $smtp2.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $smtp2.UseDefaultCredentials = $false
        $smtp2.Credentials = New-Object System.Net.NetworkCredential($emailFrom, $sendPass)
        $msg2 = New-Object System.Net.Mail.MailMessage
        $msg2.From = $emailFrom
        $msg2.To.Add($emailTo)
        $msg2.Subject = $subject
        $msg2.Body    = $body
        $smtp2.Send($msg2)
        $msg2.Dispose()
        $smtp2.Dispose()
        $ts2 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $alertsLog -Value "[INFO] [$ts2] Email sent OK: $subject -> $emailTo"
    } catch {
        $errMsg2 = $_.Exception.Message
        Write-Host "[WARN] Email send failed: $errMsg2" -ForegroundColor Yellow
        $ts2 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $alertsLog -Value "[WARN] [$ts2] Email send failed: $errMsg2"
    } finally {
        $sendPass = $null
        Remove-Variable sendPass -ErrorAction SilentlyContinue
    }
}

# Parameter overrides take priority over config
if ($InterfaceId    -gt 0) { $captureInterface = $InterfaceId }
if ($TimeoutSeconds -gt 0) { $timeoutSecs      = $TimeoutSeconds }

# Build effective interface list: multi-interface array takes precedence over scalar
if ($captureInterfaces.Count -eq 0) { $captureInterfaces = @($captureInterface) }

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if (-not (Test-Path $tsharkPath)) {
    Write-Error "tshark not found at: $tsharkPath"
    exit 1
}
if ($captureInterfaces.Count -eq 0 -or ($captureInterfaces.Count -eq 1 -and $captureInterfaces[0] -le 0)) {
    Write-Error "No capture interface set. Edit config.json (capture.interface_id or capture.interface_ids) or pass -InterfaceId."
    exit 1
}
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

# ---------------------------------------------------------------------------
# Alert writer
# ---------------------------------------------------------------------------
function Write-Alert {
    param([string]$Type, [string]$Message)
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$Type] [$ts] $Message"
    $color = switch ($Type) {
        "ALERT"    { "Red" }
        "RECOVERY" { "Green" }
        "WARN"     { "Yellow" }
        "INFO"     { "Cyan" }
        default    { "White" }
    }
    Write-Host $entry -ForegroundColor $color
    Add-Content -Path $alertsLog -Value $entry
    # Check alert suppression window — still write to log, but skip email when suppressed
    $script:emailSuppressed = $false
    if ($suppressStart -and $suppressEnd) {
        $nowT    = [DateTime]::Now
        $nowMins = $nowT.Hour * 60 + $nowT.Minute
        $sParts  = $suppressStart -split ':'
        $eParts  = $suppressEnd   -split ':'
        if ($sParts.Count -eq 2 -and $eParts.Count -eq 2) {
            $sMins = [int]$sParts[0] * 60 + [int]$sParts[1]
            $eMins = [int]$eParts[0] * 60 + [int]$eParts[1]
            if ($sMins -le $eMins) {
                $script:emailSuppressed = ($nowMins -ge $sMins -and $nowMins -lt $eMins)
            } else {
                # Window spans midnight
                $script:emailSuppressed = ($nowMins -ge $sMins -or $nowMins -lt $eMins)
            }
        }
    }
    if (-not $script:emailSuppressed) { Send-AlertEmail -Type $Type -Message $Message }
    if (-not $script:emailSuppressed) { Send-NtfyNotification -Type $Type -Message $Message }
    if ($Type -eq 'ALERT') {
        if (-not $script:emailSuppressed) { Invoke-AudioAlert -IsRecovery $false }
        $script:sessionAlertCount++
        Start-AlertCapture -AlertMessage $Message
    }
    if ($Type -eq 'RECOVERY') {
        if (-not $script:emailSuppressed) { Invoke-AudioAlert -IsRecovery $true }
        $script:sessionRecoveryCount++
    }
}

# ---------------------------------------------------------------------------
# ntfy.sh push notification (fire-and-forget, non-blocking via job)
# ---------------------------------------------------------------------------
function Send-NtfyNotification {
    param([string]$Type, [string]$Message)
    if (-not $ntfyEnabled -or -not $ntfyTopic) { return }
    $priority = switch ($Type) {
        'ALERT'    { 'urgent' }
        'WARN'     { 'default' }
        'RECOVERY' { 'low' }
        default    { 'default' }
    }
    $tags = switch ($Type) {
        'ALERT'    { 'warning,rotating_light' }
        'RECOVERY' { 'white_check_mark' }
        default    { 'information_source' }
    }
    $url = "$($ntfyServer.TrimEnd('/'))/$ntfyTopic"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('Title',    "Art-Net $Type on $(hostname)")
        $wc.Headers.Add('Priority', $priority)
        $wc.Headers.Add('Tags',     $tags)
        [void]$wc.UploadString($url, $Message)
        $wc.Dispose()
    } catch {
        $ntfyErr = $_.Exception.Message
        $logTs   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $alertsLog -Value "[WARN] [$logTs] ntfy send failed: $ntfyErr"
    }
}

# ---------------------------------------------------------------------------
# Local audio alert
# ALERT: high tone (or alert.wav); RECOVERY: low tone (or recovery.wav)
# Suppressed during the alert suppression window (same flag as email)
# ---------------------------------------------------------------------------
function Invoke-AudioAlert {
    param([bool]$IsRecovery)
    if (-not $audioEnabled) { return }
    if ($audioFile -and (Test-Path $audioFile)) {
        try {
            $player = New-Object System.Media.SoundPlayer($audioFile)
            $player.Play()  # async, non-blocking
        } catch {}
    } else {
        if ($IsRecovery) {
            [console]::Beep(440, 200)
        } else {
            [console]::Beep(880, 300)
            Start-Sleep -Milliseconds 100
            [console]::Beep(880, 300)
        }
    }
}

# ---------------------------------------------------------------------------
# Triggered .pcap capture on ALERT (background process, non-blocking)
# Filename: alert_U{universe}_{timestamp}.pcap saved to captures dir
# ---------------------------------------------------------------------------
function Start-AlertCapture {
    param([string]$AlertMessage)
    if (-not $captureOnAlert) { return }
    if (-not (Test-Path $capturesDir)) {
        try { New-Item -ItemType Directory -Path $capturesDir -Force | Out-Null } catch { return }
    }
    # Extract universe number from alert message text if present
    $uniTag = ''
    if ($AlertMessage -match 'Universe (\d+)') { $uniTag = "_U$($Matches[1])" }
    $ts2      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $pcapFile = Join-Path $capturesDir "alert${uniTag}_${ts2}.pcap"
    try {
        $capPsi                        = New-Object System.Diagnostics.ProcessStartInfo
        $capPsi.FileName               = $tsharkPath
        $capPsi.Arguments              = "-i $captureInterface -f `"udp port 6454`" -a duration:$captureDurationSecs -w `"$pcapFile`""
        $capPsi.RedirectStandardOutput = $false
        $capPsi.RedirectStandardError  = $false
        $capPsi.UseShellExecute        = $false
        $capPsi.CreateNoWindow         = $true
        [void][System.Diagnostics.Process]::Start($capPsi)
        $logTs = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $alertsLog -Value "[INFO] [$logTs] .pcap capture started: $pcapFile (${captureDurationSecs}s)"
    } catch {
        $capErr = $_.Exception.Message
        $logTs  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $alertsLog -Value "[WARN] [$logTs] .pcap capture failed to start: $capErr"
    }
}

# ---------------------------------------------------------------------------
# Session summary email (sent once on clean exit via finally)
# ---------------------------------------------------------------------------
function Send-SessionSummaryEmail {
    if (-not $emailEnabled)                    { return }
    if (-not $emailFrom -or -not $emailTo)     { return }
    $sendPass = ''
    try {
        $sendCfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($sendCfg.email.app_password) { $sendPass = $sendCfg.email.app_password }
    } catch {}
    if (-not $sendPass -or $sendPass -match '^xxxx') { return }
    $now       = [DateTime]::Now
    $uptime    = [int]($now - $monitorStart).TotalSeconds
    $uptimeStr = '{0:D2}h {1:D2}m {2:D2}s' -f [int]($uptime / 3600), [int](($uptime % 3600) / 60), ($uptime % 60)
    $neverSeen = @($expectedUnis | Where-Object {
        -not $universeTable.ContainsKey([int]$_) -or -not $universeTable[[int]$_].EverSeen
    })
    $rateOverloads = @($universeTable.Keys | Where-Object { $universeTable[$_].RateAlerted })
    $sacnConflicts = @($sacnWarnTimes.Keys)
    $lines = @(
        '=== Art-Net Monitor Session Summary ===',
        "Host      : $(hostname)",
        "Uptime    : $uptimeStr",
        "Packets   : $packetCount",
        '',
        "Alerts    : $($script:sessionAlertCount)",
        "Recoveries: $($script:sessionRecoveryCount)",
        ''
    )
    if ($neverSeen.Count -gt 0) {
        $lines += "Universes never seen : $($neverSeen -join ', ')"
    } else {
        $lines += 'All expected universes were seen.'
    }
    if ($rateOverloads.Count -gt 0) { $lines += "Rate overload (U)    : $($rateOverloads -join ', ')" }
    if ($sacnConflicts.Count  -gt 0) { $lines += "sACN conflicts (U)   : $($sacnConflicts  -join ', ')" }
    try {
        $subject = "[Art-Net Monitor] Session Summary - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        $body    = $lines -join "`r`n"
        $smtp3   = New-Object System.Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtp3.EnableSsl             = $smtpUseSSL
        $smtp3.DeliveryMethod        = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $smtp3.UseDefaultCredentials = $false
        $smtp3.Credentials           = New-Object System.Net.NetworkCredential($emailFrom, $sendPass)
        $msg3         = New-Object System.Net.Mail.MailMessage
        $msg3.From    = $emailFrom
        $msg3.To.Add($emailTo)
        $msg3.Subject = $subject
        $msg3.Body    = $body
        $smtp3.Send($msg3)
        $msg3.Dispose()
        $smtp3.Dispose()
        $logTs = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $alertsLog -Value "[INFO] [$logTs] Session summary email sent -> $emailTo"
    } catch {
        $sumErr = $_.Exception.Message
        $logTs  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $alertsLog -Value "[WARN] [$logTs] Session summary email failed: $sumErr"
    } finally {
        $sendPass = $null
        Remove-Variable sendPass -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Log rotation: called once at startup before first write
# ---------------------------------------------------------------------------
function Rotate-AlertsLog {
    if (-not (Test-Path $alertsLog)) { return }
    $sizeBytes = (Get-Item $alertsLog).Length
    if ($sizeBytes -lt ($logMaxSizeMB * 1MB)) { return }
    $logDir  = Split-Path $alertsLog -Parent
    $logLeaf = Split-Path $alertsLog -Leaf
    # Shift existing rotated files up; delete oldest when it exceeds keep_count
    for ($i = ($logKeepCount - 1); $i -ge 1; $i--) {
        $src = Join-Path $logDir "$logLeaf.$i"
        $dst = Join-Path $logDir "$logLeaf.$($i + 1)"
        if (Test-Path $dst) { Remove-Item $dst -Force }
        if (Test-Path $src) { Rename-Item -Path $src -NewName "$logLeaf.$($i + 1)" -Force }
    }
    Rename-Item -Path $alertsLog -NewName "$logLeaf.1" -Force
    Write-Host "[INFO] alerts.log rotated ($([math]::Round($sizeBytes / 1MB, 1)) MB exceeded ${logMaxSizeMB}MB threshold)" -ForegroundColor DarkCyan
}

# ---------------------------------------------------------------------------
# Art-Net universe extraction from raw UDP payload hex (fallback parser)
# ArtDmx packet: ID(8) OpCode(2) ProtVer(2) Seq(1) Phys(1) Universe(2) Len(2) Data(512)
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

# ---------------------------------------------------------------------------
# Universe tracking state
# Table key: universe number (int)
# Entry: @{ LastSeen; Sources; Alerted; WarnedDup; EverSeen; RateAlerted; LastSeq; PrimarySource; PrimaryLastSeen; HijackWarned; AlertTime; LastSourceBeforeAlert; JitterAlerted }
# ---------------------------------------------------------------------------
$universeTable  = @{}
$monitorStart   = [DateTime]::Now
$lastStatusTime = [DateTime]::Now
$packetCount    = 0
$script:sessionAlertCount    = 0
$script:sessionRecoveryCount = 0

function Initialize-Universe([int]$uni) {
    if (-not $universeTable.ContainsKey($uni)) {
        $universeTable[$uni] = @{
            LastSeen              = $null
            Sources               = @{}
            Alerted               = $false
            WarnedDup             = $false
            EverSeen              = $false
            RateAlerted           = $false
            LastSeq               = -1      # Feature 1: last seen sequence byte (-1 = not yet seen)
            PrimarySource         = $null   # Feature 2: established primary sender IP
            PrimaryLastSeen       = $null   # Feature 2: last packet time from primary source
            HijackWarned          = $false  # Feature 2: hijack alert already fired
            AlertTime             = $null   # Feature 3: when the drop alert fired
            LastSourceBeforeAlert = $null   # Feature 3: dominant source IP at alert time
            JitterAlerted         = $false  # Feature 4: jitter alert currently active
        }
    }
}

foreach ($uni in $expectedUnis) { Initialize-Universe ([int]$uni) }

# Per-universe 1-second sliding rate window (Queue of timestamps)
$uniRateQ       = @{}
# ARP: ip -> mac (detect IP conflicts)
$arpTable       = @{}
# sACN: universe -> DateTime last warned (suppress repeat within 5 min)
$sacnWarnTimes  = @{}
# Art-Net control packet last-warned time (suppress rapid repeats)
$artCmdWarnTime = [DateTime]::MinValue

# ---------------------------------------------------------------------------
# Additional detection helpers
# ---------------------------------------------------------------------------

# Returns Art-Net OpCode (int) or $null if packet is not Art-Net
function Get-ArtNetOpCode([string]$hexRaw) {
    $hex = $hexRaw -replace '[^0-9a-fA-F]', ''
    if ($hex.Length -lt 20) { return $null }
    if ($hex.Substring(0, 16).ToLower() -ne '4172742d4e657400') { return $null }
    $opLow  = [Convert]::ToByte($hex.Substring(16, 2), 16)
    $opHigh = [Convert]::ToByte($hex.Substring(18, 2), 16)
    return ($opHigh -shl 8) -bor $opLow
}

# Returns ArtDmx sequence byte (0 = sequencing disabled), or $null if not ArtDmx
function Get-ArtNetSequence([string]$hexRaw) {
    $hex = $hexRaw -replace '[^0-9a-fA-F]', ''
    if ($hex.Length -lt 32) { return $null }
    if ($hex.Substring(0, 16).ToLower() -ne '4172742d4e657400') { return $null }
    try {
        if ([Convert]::ToByte($hex.Substring(16, 2), 16) -ne 0x00) { return $null }
        if ([Convert]::ToByte($hex.Substring(18, 2), 16) -ne 0x50) { return $null }
        return [int][Convert]::ToByte($hex.Substring(24, 2), 16)
    } catch { return $null }
}

# Returns sACN universe from multicast destination IP 239.255.X.Y, or $null
function Get-SACNUniverse([string]$dstIP) {
    if ($dstIP -match '^239\.255\.(\d+)\.(\d+)$') {
        return [int]$Matches[1] * 256 + [int]$Matches[2]
    }
    return $null
}

# ---------------------------------------------------------------------------
# Timeout / anomaly check (runs every checkIntervalMs regardless of traffic)
# ---------------------------------------------------------------------------
function Invoke-TimeoutCheck {
    $now    = [DateTime]::Now
    $uptime = ($now - $monitorStart).TotalSeconds

    foreach ($uni in ($universeTable.Keys | Sort-Object)) {
        $entry = $universeTable[$uni]

        if (-not $entry.EverSeen) {
            # Never seen - alert only after grace period and only for expected universes
            if ($uptime -gt $startupGrace -and ($expectedUnis -contains $uni) -and -not $entry.Alerted) {
                Write-Alert "ALERT" "Universe $uni never appeared (expected but not seen after ${startupGrace}s startup)"
                $universeTable[$uni].Alerted = $true
            }
            continue
        }

        # Previously seen - check if it has gone silent
        $age = ($now - $entry.LastSeen).TotalSeconds
        if ($age -gt $timeoutSecs -and -not $entry.Alerted) {
            $lastSeenStr = $entry.LastSeen.ToString("HH:mm:ss")
            Write-Alert "ALERT" "Universe $uni missing for >${timeoutSecs}s (last seen: $lastSeenStr)"
            $universeTable[$uni].Alerted = $true
            # Feature 3: record alert context for reboot fingerprinting on recovery
            $universeTable[$uni].AlertTime = $now
            $universeTable[$uni].LastSourceBeforeAlert = ($entry.Sources.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        }
    }
}

# ---------------------------------------------------------------------------
# Periodic status summary (printed to console only, not logged)
# ---------------------------------------------------------------------------
function Write-StatusSummary {
    $now    = [DateTime]::Now
    $uptime = [int]($now - $monitorStart).TotalSeconds
    Write-Host ""
    Write-Host "--- Status @ $($now.ToString('HH:mm:ss'))  uptime:${uptime}s  packets:$packetCount ---" -ForegroundColor DarkCyan
    $activeUnis = $universeTable.Keys | Sort-Object
    if ($activeUnis.Count -eq 0) {
        Write-Host "  No universes seen yet." -ForegroundColor DarkYellow
    } else {
        foreach ($uni in $activeUnis) {
            $e = $universeTable[$uni]
            if ($e.EverSeen) {
                $age    = [int]($now - $e.LastSeen).TotalSeconds
                $hz     = if ($uniRateQ.ContainsKey($uni)) { $uniRateQ[$uni].Count } else { 0 }
                $state  = if ($e.Alerted)     { 'DROPPED ' }
                         elseif ($e.RateAlerted) { 'OVERLOAD' }
                         else                    { 'OK      ' }
                $color  = if ($e.Alerted)     { 'Red' }
                         elseif ($e.RateAlerted) { 'Yellow' }
                         else                    { 'DarkGreen' }
                Write-Host "  Universe $uni  $state  last:${age}s ago  ~${hz}Hz  src:$($e.Sources.Count)" -ForegroundColor $color
            } elseif ($expectedUnis -contains $uni) {
                Write-Host "  Universe $uni  [not yet seen]" -ForegroundColor DarkYellow
            }
        }
    }
    # Network health summary
    $rateOverloads = @($universeTable.Keys | Where-Object { $universeTable[$_].RateAlerted })
    if ($rateOverloads.Count -gt 0) {
        Write-Host "  RATE OVERLOAD on U: $($rateOverloads -join ', ')" -ForegroundColor Red
    }
    $jitterAlerts = @($universeTable.Keys | Where-Object { $universeTable[$_].JitterAlerted })
    if ($jitterAlerts.Count -gt 0) {
        Write-Host "  HIGH JITTER on U: $($jitterAlerts -join ', ')" -ForegroundColor Yellow
    }
    if ($sacnWarnTimes.Count -gt 0) {
        Write-Host "  sACN conflict detected for U: $($sacnWarnTimes.Keys -join ', ')" -ForegroundColor Yellow
    }
    if ($arpTable.Count -gt 0) {
        Write-Host "  ARP table: $($arpTable.Count) IPs tracked" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Universe status JSON (read by the GUI health-grid every ~2 s)
# Written atomically via temp-file + rename to avoid partial JSON reads.
# ---------------------------------------------------------------------------
function Write-UniverseStatus {
    $now     = [DateTime]::Now
    $uniData = [ordered]@{}
    foreach ($uni in ($universeTable.Keys | Sort-Object)) {
        $e     = $universeTable[$uni]
        $age   = if ($e.EverSeen) { [math]::Round(($now - $e.LastSeen).TotalSeconds, 1) } else { 9999 }
        $hz    = if ($uniRateQ.ContainsKey($uni)) { $uniRateQ[$uni].Count } else { 0 }
        $state = if (-not $e.EverSeen)   { 'NEVER_SEEN' }
                 elseif ($e.Alerted)     { 'DROPPED' }
                 elseif ($e.RateAlerted) { 'OVERLOAD' }
                 else                    { 'OK' }
        $uniData["$uni"] = [ordered]@{
            state         = $state
            last_seen_age = $age
            hz            = $hz
            sources       = $e.Sources.Count
            ever_seen     = $e.EverSeen
        }
    }
    $payload = [ordered]@{ updated = $now.ToString('yyyy-MM-ddTHH:mm:ss'); universes = $uniData }
    try {
        $json  = $payload | ConvertTo-Json -Depth 4
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $fs    = [System.IO.File]::Open($statusJsonPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Close()
    } catch {}
}

# ---------------------------------------------------------------------------
# Build tshark argument template (interface substituted per-process)
# ---------------------------------------------------------------------------
function Get-TsharkArgs([int]$ifaceId) {
    return @(
        "-i", $ifaceId,
        "-f", "`"(udp port 6454) or (udp port 5568) or arp`"",
        "-s", "80",
        "-T", "fields",
        "-e", "frame.time_epoch",
        "-e", "ip.src",
        "-e", "ip.dst",
        "-e", "udp.dstport",
        "-e", "udp.payload",
        "-e", "arp.src.proto_ipv4",
        "-e", "arp.src.hw_mac",
        "-E", "separator=|",
        "-l"
    )
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "   Art-Net Universe Monitor" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Interfaces    : $($captureInterfaces -join ', ')" -ForegroundColor Gray
Write-Host "Timeout       : ${timeoutSecs}s" -ForegroundColor Gray
Write-Host "Expected unis : $($expectedUnis -join ', ')" -ForegroundColor Gray
Write-Host "Grace period  : ${startupGrace}s" -ForegroundColor Gray
Write-Host "Alerts log    : $alertsLog" -ForegroundColor Gray
Write-Host "Fault detection: rate>${rateWarnHz}Hz | jitter>${jitterWarnMs}ms | sACN=$(if($detectSACN){'on'}else{'off'}) | ARP=$(if($detectARPConflict){'on'}else{'off'}) | ArtCmd=$(if($warnArtCommand){'on'}else{'off'})" -ForegroundColor DarkGray
Write-Host "Log rotation    : max=${logMaxSizeMB}MB keep=${logKeepCount} | Alert capture: $(if($captureOnAlert){'on ('+$captureDurationSecs+'s)'}else{'off'})" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Events will appear below. Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""
Rotate-AlertsLog
Write-Alert "INFO" "Monitor started - interfaces:$($captureInterfaces -join ',')  universes:$($expectedUnis -join ',')  timeout:${timeoutSecs}s"

# ---------------------------------------------------------------------------
# Start tshark and run main monitoring loop
# ---------------------------------------------------------------------------
$procs     = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$readers   = $null   # array of Task<string>, one per process
$proc      = $null   # kept for single-interface backward-compat reference in finally
try {
    # Start one tshark process per interface
    foreach ($ifaceId in $captureInterfaces) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $tsharkPath
        $psi.Arguments              = (Get-TsharkArgs $ifaceId) -join " "
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $p) { throw "Process.Start returned null for interface $ifaceId - tshark failed to launch." }
        $procs.Add($p)
    }
    $proc = $procs[0]  # reference for legacy finally cleanup

    # Seed one outstanding ReadLineAsync per process
    $readers = $procs | ForEach-Object { $_.StandardOutput.ReadLineAsync() }
    $readers = [System.Threading.Tasks.Task[]]$readers

    while ($true) {
        # Wait up to checkIntervalMs for ANY process to produce a line
        $idx = [System.Threading.Tasks.Task]::WaitAny($readers, $checkIntervalMs)

        if ($idx -ge 0) {
            $line = $null
            try { $line = $readers[$idx].Result } catch { break }
            if ($null -eq $line) { break }  # stdout closed (process ended)

            if (-not [string]::IsNullOrWhiteSpace($line)) {
                # Field layout (tshark -T fields):
                #  0=frame.time_epoch  1=ip.src  2=ip.dst  3=udp.dstport
                #  4=udp.payload  5=arp.src.proto_ipv4  6=arp.src.hw_mac
                $parts     = $line.Split('|')
                $srcIp     = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
                $dstIp     = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '' }
                $dstPort   = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }
                $hexPay    = if ($parts.Count -gt 4) { $parts[4].Trim() } else { '' }
                $arpSrcIP  = if ($parts.Count -gt 5) { $parts[5].Trim() } else { '' }
                $arpSrcMAC = if ($parts.Count -gt 6) { $parts[6].Trim() } else { '' }

                # ==========================================================
                # ARP conflict detection
                # If an IP appears with a different MAC it may mean another
                # device has claimed the same IP as an eNode - the node will
                # lose network access and all its universes will drop.
                # ==========================================================
                if ($detectARPConflict -and $arpSrcIP -ne '' -and $arpSrcMAC -ne '') {
                    # Normalize MAC to uppercase hex digits only for reliable comparison
                    $normMAC = ($arpSrcMAC -replace '[^0-9A-Fa-f]', '').ToUpper()
                    if (-not $arpTable.ContainsKey($arpSrcIP)) {
                        $arpTable[$arpSrcIP] = $normMAC
                    } elseif ($arpTable[$arpSrcIP] -ne $normMAC) {
                        Write-Alert 'WARN' "ARP IP conflict: $arpSrcIP changed from MAC $($arpTable[$arpSrcIP]) to $normMAC - if this is an eNode IP it has lost network access!"
                        $arpTable[$arpSrcIP] = $normMAC
                    }
                }

                # ==========================================================
                # sACN (E1.31) competition detection  (UDP port 5568)
                # eNode4/8 has sACN auto-detection - if sACN appears for a
                # universe the node is outputting via Art-Net, the node may
                # silently switch protocols and the Art-Net output stops.
                # ==========================================================
                if ($detectSACN -and $dstPort -eq '5568' -and $dstIp -ne '') {
                    $sacnUni = Get-SACNUniverse $dstIp
                    if ($null -ne $sacnUni -and ($expectedUnis -contains $sacnUni)) {
                        $lastWarn = if ($sacnWarnTimes.ContainsKey($sacnUni)) { $sacnWarnTimes[$sacnUni] } else { [DateTime]::MinValue }
                        if (([DateTime]::Now - $lastWarn).TotalSeconds -gt 300) {
                            Write-Alert 'WARN' "sACN (E1.31) detected for Universe $sacnUni from $srcIp - eNode sACN auto-detection may switch this universe away from Art-Net, causing DMX output fault!"
                            $sacnWarnTimes[$sacnUni] = [DateTime]::Now
                        }
                    }
                }

                # ==========================================================
                # Art-Net processing  (UDP port 6454)
                # ==========================================================
                if ($dstPort -eq '6454' -and $hexPay.Length -ge 32) {

                    # ----------------------------------------------------------
                    # Art-Net control packet detection
                    # ArtAddress (0x6000) can change port direction, subnet,
                    # universe, or put port into standby.  ArtInput (0x7000)
                    # can disable input ports.  Neither should appear during a
                    # live show unless you're intentionally reconfiguring nodes.
                    # ----------------------------------------------------------
                    if ($warnArtCommand) {
                        $opCode = Get-ArtNetOpCode $hexPay
                        $ignoredOps = @(0x5000, 0x2100, 0x2110, 0x9100, 0x9200, 0xA800, 0x0200)
                        if ($null -ne $opCode -and $opCode -notin $ignoredOps) {
                            $opName = switch ($opCode) {
                                0x6000 { 'ArtAddress (node reconfiguration - can change port direction or put port to standby!)' }
                                0x7000 { 'ArtInput (can disable eNode input ports!)' }
                                0x6100 { 'ArtFirmwareMaster (firmware update - node will reboot!)' }
                                default { "Unknown OpCode 0x$('{0:X4}' -f $opCode)" }
                            }
                            if (([DateTime]::Now - $artCmdWarnTime).TotalSeconds -gt 30) {
                                Write-Alert 'WARN' "Art-Net CONTROL packet from ${srcIp}: $opName"
                                $artCmdWarnTime = [DateTime]::Now
                            }
                        }
                    }

                    # ----------------------------------------------------------
                    # ArtDmx universe tracking + rate overload detection
                    # ----------------------------------------------------------
                    $universe = Get-ArtNetUniverse $hexPay
                    if ($null -ne $universe -and $srcIp -ne '') {
                        $packetCount++
                        $now = [DateTime]::Now
                        Initialize-Universe $universe

                        # --- Rate overload (Art-Net spec: max 44 pkt/s) ---
                        if (-not $uniRateQ.ContainsKey($universe)) {
                            $uniRateQ[$universe] = [System.Collections.Generic.Queue[DateTime]]::new()
                        }
                        $uniRateQ[$universe].Enqueue($now)
                        while ($uniRateQ[$universe].Count -gt 0 -and
                               ($now - $uniRateQ[$universe].Peek()).TotalSeconds -gt 1.0) {
                            [void]$uniRateQ[$universe].Dequeue()
                        }
                        $hz = $uniRateQ[$universe].Count
                        if ($hz -gt $rateWarnHz -and -not $universeTable[$universe].RateAlerted) {
                            Write-Alert 'WARN' "Universe $universe rate overload: ~${hz} pkt/s exceeds Art-Net limit of ${rateWarnHz} pkt/s - eNode may buffer-fault and halt DMX output!"
                            $universeTable[$universe].RateAlerted = $true
                        } elseif ($hz -le $rateWarnHz -and $universeTable[$universe].RateAlerted) {
                            Write-Alert 'INFO' "Universe $universe rate normalized: ~${hz} pkt/s"
                            $universeTable[$universe].RateAlerted = $false
                        }

                        # --- Inter-packet jitter (Feature 4) ---
                        if ($uniRateQ[$universe].Count -ge 5) {
                            $times    = $uniRateQ[$universe].ToArray()
                            $gapSum   = 0.0; $gapSumSq = 0.0; $gapN = $times.Count - 1
                            for ($gi = 1; $gi -lt $times.Count; $gi++) {
                                $g = ($times[$gi] - $times[$gi-1]).TotalMilliseconds
                                $gapSum += $g; $gapSumSq += $g * $g
                            }
                            $meanMs   = $gapSum / $gapN
                            $stddevMs = [Math]::Round([Math]::Sqrt([Math]::Max(0, ($gapSumSq / $gapN) - $meanMs * $meanMs)), 1)
                            if ($stddevMs -gt $jitterWarnMs -and -not $universeTable[$universe].JitterAlerted) {
                                Write-Alert 'WARN' "Universe $universe jitter: stddev ${stddevMs}ms exceeds ${jitterWarnMs}ms threshold - network congestion likely"
                                $universeTable[$universe].JitterAlerted = $true
                            } elseif ($stddevMs -le $jitterWarnMs -and $universeTable[$universe].JitterAlerted) {
                                Write-Alert 'INFO' "Universe $universe jitter normalized: stddev ${stddevMs}ms"
                                $universeTable[$universe].JitterAlerted = $false
                            }
                        }

                        # Recovery: universe was alerted but traffic resumed
                        if ($universeTable[$universe].Alerted) {
                            # Feature 3: fingerprint short-gap same-IP return as node reboot
                            $alertAge = if ($null -ne $universeTable[$universe].AlertTime) {
                                ($now - $universeTable[$universe].AlertTime).TotalSeconds
                            } else { 9999 }
                            $prevSrc = $universeTable[$universe].LastSourceBeforeAlert
                            if ($alertAge -lt 30 -and $null -ne $prevSrc -and $srcIp -eq $prevSrc) {
                                Write-Alert 'INFO' "Universe $universe source ${srcIp} rebooted (gap: $([int]$alertAge)s)"
                            } else {
                                Write-Alert 'RECOVERY' "Universe $universe resumed (from $srcIp)"
                            }
                            $universeTable[$universe].Alerted        = $false
                            $universeTable[$universe].WarnedDup      = $false
                            $universeTable[$universe].LastSeq        = -1
                            $universeTable[$universe].JitterAlerted  = $false
                        }

                        # First time we see this universe
                        if (-not $universeTable[$universe].EverSeen) {
                            Write-Alert 'INFO' "Universe $universe first seen from $srcIp"
                            $universeTable[$universe].EverSeen = $true
                        }

                        $universeTable[$universe].LastSeen = $now

                        # --- Sequence discontinuity tracking (Feature 1) ---
                        $seq = Get-ArtNetSequence $hexPay
                        if ($null -ne $seq -and $seq -ne 0 -and $universeTable[$universe].LastSeq -ge 0) {
                            $prevSeq     = $universeTable[$universe].LastSeq
                            $expectedSeq = if ($prevSeq -ge 255) { 1 } else { $prevSeq + 1 }
                            if ($seq -ne $expectedSeq) {
                                Write-Alert 'WARN' "Universe $universe sequence gap: expected $expectedSeq got $seq (delta: $($seq - $prevSeq))"
                            }
                        }
                        if ($null -ne $seq -and $seq -ne 0) { $universeTable[$universe].LastSeq = $seq }

                        # Track source IPs
                        if (-not $universeTable[$universe].Sources.ContainsKey($srcIp)) {
                            $universeTable[$universe].Sources[$srcIp] = 0
                        }
                        $universeTable[$universe].Sources[$srcIp]++

                        # --- Source IP hijack detection (Feature 2) ---
                        $uptime = ($now - $monitorStart).TotalSeconds
                        if ($uptime -gt $startupGrace) {
                            if ($null -eq $universeTable[$universe].PrimarySource) {
                                $universeTable[$universe].PrimarySource   = $srcIp
                                $universeTable[$universe].PrimaryLastSeen = $now
                            } elseif ($srcIp -eq $universeTable[$universe].PrimarySource) {
                                $universeTable[$universe].PrimaryLastSeen = $now
                                if ($universeTable[$universe].HijackWarned) {
                                    Write-Alert 'INFO' "Universe $universe primary source ${srcIp} resumed sending"
                                    $universeTable[$universe].HijackWarned = $false
                                }
                            } else {
                                $primarySilent = if ($null -ne $universeTable[$universe].PrimaryLastSeen) {
                                    ($now - $universeTable[$universe].PrimaryLastSeen).TotalSeconds
                                } else { 9999 }
                                if ($primarySilent -gt $timeoutSecs -and -not $universeTable[$universe].HijackWarned) {
                                    Write-Alert 'WARN' "Universe $universe source hijack: primary $($universeTable[$universe].PrimarySource) silent $([int]$primarySilent)s, ${srcIp} is now sending"
                                    $universeTable[$universe].HijackWarned = $true
                                }
                            }
                        }

                        # Duplicate source warning
                        if ($warnDuplicate -and
                            $universeTable[$universe].Sources.Count -gt 1 -and
                            -not $universeTable[$universe].WarnedDup) {
                            $srcs = @($universeTable[$universe].Sources.Keys)
                            Write-Alert 'WARN' "Duplicate source for Universe $universe - IPs: $($srcs -join ', ')"
                            $universeTable[$universe].WarnedDup = $true
                        }
                    }
                }
            }

            # Re-arm this reader for the next line from the same process
            $readers[$idx] = $procs[$idx].StandardOutput.ReadLineAsync()
        }

        # Always check timeouts (even when no packets arrive)
        Invoke-TimeoutCheck
        Write-UniverseStatus

        # Periodic status summary
        if (([DateTime]::Now - $lastStatusTime).TotalSeconds -ge $statusInterval) {
            Write-StatusSummary
            $lastStatusTime = [DateTime]::Now
        }
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host ""
} finally {
    foreach ($p in $procs) {
        if ($null -ne $p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
        try { if ($null -ne $p) { $p.Dispose() } } catch {}
    }

    $exitCode = if ($null -ne $proc -and $proc.HasExited) { $proc.ExitCode } else { "N/A" }
    Write-StatusSummary
    Write-UniverseStatus
    Write-Alert "INFO" "Monitor stopped. Packets:$packetCount  tshark exit:$exitCode"
    Send-SessionSummaryEmail
    Write-Host "Monitor stopped." -ForegroundColor Gray
    Write-Host ""
    Read-Host "Press Enter to close"
}
