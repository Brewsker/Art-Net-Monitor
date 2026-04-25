# artnet-monitor-gui.ps1
# Art-Net Monitor Control Panel - Windows GUI (PowerShell / WinForms)
#
# Run on RADIO PC (as Administrator for tshark capture to work).
#
# Usage:
#   .\artnet-monitor-gui.ps1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Hide the PowerShell console window - works regardless of how the script is launched
Add-Type -Name ConsoleHide -Namespace Win32 -MemberDefinition @'
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
[Win32.ConsoleHide]::ShowWindow([Win32.ConsoleHide]::GetConsoleWindow(), 0) | Out-Null

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ConfigPath  = "C:\AV-Monitoring\config.json"
$TsharkPath  = "C:\Program Files\Wireshark\tshark.exe"
$ScriptsPath = "C:\AV-Monitoring\scripts"
$AlertsLog      = "C:\AV-Monitoring\logs\alerts.log"
$IPHistoryPath  = "C:\AV-Monitoring\ip_history.json"
$GenControlFile = "C:\AV-Monitoring\generator-control.json"
$StatusJsonPath = "C:\AV-Monitoring\logs\universe-status.json"

# ---------------------------------------------------------------------------
# Script-level state
# ---------------------------------------------------------------------------
$script:cfg                = $null
$script:monitorProc        = $null
$script:generatorProc      = $null
$script:logLineOffset      = 0     # lines already displayed; cleared by Clear Display
$script:suppressGenControl = $false

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
function Load-Config {
    if (Test-Path $ConfigPath) {
        try { $script:cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
        catch { $script:cfg = $null }
    }
}

function Save-Config {
    param(
        [int]$InterfaceId, [int[]]$Universes, [int]$Timeout, [int]$Grace,
        # Alert suppression
        [string]$SuppressStart = '', [string]$SuppressEnd = '',
        # Email params
        [bool]$EmailEnabled, [string]$SmtpServer, [int]$SmtpPort, [bool]$UseSSL,
        [string]$FromAddr, [string]$AppPass, [string]$ToAddr,
        # Push/audio params
        [bool]$NtfyEnabled, [string]$NtfyTopic, [string]$NtfyServer,
        [bool]$AudioEnabled, [string]$AudioFile,
        # Generator params
        [string]$GenDestIP, [string]$GenSrcIP,
        [int]$GenCount, [int]$GenStart, [int]$GenPPS, [int[]]$GenEnabled
    )
    # Preserve existing email/generator/alerts values if not supplied
    Load-Config
    $existingEmail  = if ($script:cfg -and $script:cfg.email)   { $script:cfg.email }   else { $null }
    $existingGen    = if ($script:cfg -and $script:cfg.generator){ $script:cfg.generator } else { $null }
    $existingAlerts = if ($script:cfg -and $script:cfg.alerts)  { $script:cfg.alerts }  else { $null }

    $emailObj = [ordered]@{
        enabled      = $EmailEnabled
        smtp_server  = if ($SmtpServer) { $SmtpServer } elseif ($existingEmail) { $existingEmail.smtp_server } else { 'smtp.gmail.com' }
        smtp_port    = if ($SmtpPort -gt 0) { $SmtpPort } elseif ($existingEmail) { [int]$existingEmail.smtp_port } else { 587 }
        use_ssl      = $UseSSL
        from_address = if ($FromAddr) { $FromAddr } elseif ($existingEmail) { $existingEmail.from_address } else { '' }
        app_password = if ($AppPass) { $AppPass } elseif ($existingEmail) { $existingEmail.app_password } else { '' }
        to_address   = if ($ToAddr) { $ToAddr } elseif ($existingEmail) { $existingEmail.to_address } else { '' }
        alert_types  = @('ALERT','RECOVERY')
    }
    $alertsObj = [ordered]@{
        ntfy_enabled  = $NtfyEnabled
        ntfy_topic    = if ($PSBoundParameters.ContainsKey('NtfyTopic'))  { $NtfyTopic }  elseif ($existingAlerts) { $existingAlerts.ntfy_topic }  else { '' }
        ntfy_server   = if ($PSBoundParameters.ContainsKey('NtfyServer')) { $NtfyServer } elseif ($existingAlerts) { $existingAlerts.ntfy_server } else { 'https://ntfy.sh' }
        audio_enabled = $AudioEnabled
        audio_file    = if ($PSBoundParameters.ContainsKey('AudioFile'))  { $AudioFile }  elseif ($existingAlerts) { $existingAlerts.audio_file }  else { '' }
    }
    $genObj = [ordered]@{
        destination_ip    = if ($GenDestIP) { $GenDestIP } elseif ($existingGen) { $existingGen.destination_ip } else { '255.255.255.255' }
        source_ip         = if ($PSBoundParameters.ContainsKey('GenSrcIP')) { $GenSrcIP } elseif ($existingGen) { $existingGen.source_ip } else { '' }
        universe_count    = if ($GenCount -gt 0) { $GenCount } elseif ($existingGen) { [int]$existingGen.universe_count } else { 24 }
        start_universe    = if ($GenStart -gt 0) { $GenStart } elseif ($existingGen) { [int]$existingGen.start_universe } else { 1 }
        packets_per_second = if ($GenPPS -gt 0) { $GenPPS } elseif ($existingGen) { [int]$existingGen.packets_per_second } else { 10 }
        enabled_universes = if ($GenEnabled) { $GenEnabled } else { @() }
    }
    $obj = [ordered]@{
        capture    = [ordered]@{ interface_id = $InterfaceId; filter = 'udp port 6454' }
        monitoring = [ordered]@{
            expected_universes    = $Universes
            timeout_seconds       = $Timeout
            startup_grace_seconds = $Grace
            duplicate_source_warn = $true
            check_interval_ms     = 500
            suppress_start        = $SuppressStart
            suppress_end          = $SuppressEnd
        }
        email     = $emailObj
        generator = $genObj
        alerts    = $alertsObj
        paths = [ordered]@{
            tshark     = $TsharkPath
            captures   = 'C:\AV-Monitoring\captures'
            logs       = 'C:\AV-Monitoring\logs'
            alerts_log = $AlertsLog
        }
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
    Load-Config
}

# ---------------------------------------------------------------------------
# Interface list
# ---------------------------------------------------------------------------
function Get-TsharkInterfaces {
    if (-not (Test-Path $TsharkPath)) { return [string[]]@("(tshark not found at $TsharkPath)") }
    try {
        $lines  = & $TsharkPath -D 2>&1
        $result = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ($line -match '^(\d+)\.\s+\\Device\\NPF_[^\s]+\s+\((.+?)\)') {
                $id   = $Matches[1]
                $name = $Matches[2]
                $low  = $name.ToLower()
                if ($low -match 'local area connection\*|bluetooth|etw') { continue }
                $result.Add("$id  $name") | Out-Null
            }
        }
        return $result.ToArray()
    } catch {
        return [string[]]@("(error reading interfaces: $_)")
    }
}

function Get-IdFromItem ([string]$item) {
    if ($item -match '^(\d+)') { return [int]$Matches[1] }
    return 8
}

# ---------------------------------------------------------------------------
# Theme colors
# ---------------------------------------------------------------------------
$DarkBg    = [System.Drawing.Color]::FromArgb(28,  28,  28)
$DarkInput = [System.Drawing.Color]::FromArgb(50,  50,  50)
$AccBlue   = [System.Drawing.Color]::FromArgb(86, 156, 214)
$TxtWhite  = [System.Drawing.Color]::FromArgb(220, 220, 220)
$TxtGray   = [System.Drawing.Color]::FromArgb(145, 145, 145)
$BtnGreen  = [System.Drawing.Color]::FromArgb(0,  115,  55)
$BtnRed    = [System.Drawing.Color]::FromArgb(148,  33,  33)
$BtnBlue   = [System.Drawing.Color]::FromArgb(0,   80, 160)
$BtnGray   = [System.Drawing.Color]::FromArgb(58,  58,  58)

# ---------------------------------------------------------------------------
# UI factory helpers
# ---------------------------------------------------------------------------
function New-Lbl {
    param([string]$t, [int]$x, [int]$y, [int]$w = 110, [int]$h = 20)
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $t
    $l.Location  = [System.Drawing.Point]::new($x, $y)
    $l.Size      = [System.Drawing.Size]::new($w, $h)
    $l.ForeColor = $TxtGray
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-Btn {
    param([string]$t, [int]$x, [int]$y, [int]$w, [int]$h, [System.Drawing.Color]$bg)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $t
    $b.Location  = [System.Drawing.Point]::new($x, $y)
    $b.Size      = [System.Drawing.Size]::new($w, $h)
    $b.FlatStyle = "Flat"
    $b.ForeColor = $TxtWhite
    $b.BackColor = $bg
    $b.FlatAppearance.BorderColor = $bg
    return $b
}

function New-Txt {
    param([int]$x, [int]$y, [int]$w, [string]$val = "")
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location    = [System.Drawing.Point]::new($x, $y)
    $t.Size        = [System.Drawing.Size]::new($w, 22)
    $t.Text        = $val
    $t.BackColor   = $DarkInput
    $t.ForeColor   = $TxtWhite
    $t.BorderStyle = "FixedSingle"
    return $t
}

function New-Combo {
    param([int]$x, [int]$y, [int]$w, [string]$val = "")
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location         = [System.Drawing.Point]::new($x, $y)
    $c.Size             = [System.Drawing.Size]::new($w, 22)
    $c.Text             = $val
    $c.BackColor        = $DarkInput
    $c.ForeColor        = $TxtWhite
    $c.FlatStyle        = "Flat"
    $c.DropDownStyle    = "DropDown"
    $c.MaxDropDownItems = 10
    return $c
}

function New-NumUD {
    param([int]$x, [int]$y, [int]$min, [int]$max, [int]$val)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location  = [System.Drawing.Point]::new($x, $y)
    $n.Size      = [System.Drawing.Size]::new(58, 22)
    $n.Minimum   = $min
    $n.Maximum   = $max
    $n.Value     = $val
    $n.BackColor = $DarkInput
    $n.ForeColor = $TxtWhite
    return $n
}

function New-GB {
    param([string]$t, [int]$x, [int]$y, [int]$w, [int]$h)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text      = $t
    $g.Location  = [System.Drawing.Point]::new($x, $y)
    $g.Size      = [System.Drawing.Size]::new($w, $h)
    $g.ForeColor = $AccBlue
    $g.FlatStyle = "Flat"
    return $g
}

# ===========================================================================
# Form
# ===========================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Art-Net Monitor - Control Panel"
$form.ClientSize      = [System.Drawing.Size]::new(700, 1400)
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox     = $true
$form.StartPosition   = "CenterScreen"
$form.BackColor       = $DarkBg
$form.AutoScroll      = $true
$form.MinimumSize     = [System.Drawing.Size]::new(500, 400)

# ===========================================================================
# 1. CONFIGURATION  (y=8, h=152)
# ===========================================================================
$gbCfg = New-GB "Configuration" 8 8 684 182
$form.Controls.Add($gbCfg)

$gbCfg.Controls.Add((New-Lbl "Interface:" 10 26 78))

$cboIface = New-Object System.Windows.Forms.ComboBox
$cboIface.Location      = [System.Drawing.Point]::new(92, 23)
$cboIface.Size          = [System.Drawing.Size]::new(388, 22)
$cboIface.DropDownStyle = "DropDownList"
$cboIface.BackColor     = $DarkInput
$cboIface.ForeColor     = $TxtWhite
$cboIface.FlatStyle     = "Flat"
$gbCfg.Controls.Add($cboIface)

$btnRefIface = New-Btn "Refresh" 490 22 106 26 $BtnGray
$gbCfg.Controls.Add($btnRefIface)

$gbCfg.Controls.Add((New-Lbl "Universes:" 10 56 78))
$txtUnis = New-Txt 92 53 195 "0, 1, 2, 3"
$gbCfg.Controls.Add($txtUnis)

# Quick-fill: enter a count N, click Fill to populate CSV with 1..N
$gbCfg.Controls.Add((New-Lbl "Quick fill 1-N:" 298 56 95 20))
$numQuickFill = New-NumUD 398 53 1 32767 4
$gbCfg.Controls.Add($numQuickFill)
$btnQuickFill = New-Btn "Fill" 462 52 50 24 $BtnGray
$gbCfg.Controls.Add($btnQuickFill)

$gbCfg.Controls.Add((New-Lbl "Drop Timeout:" 10 86 95))
$numTimeout = New-NumUD 108 83 1 120 2
$gbCfg.Controls.Add($numTimeout)
$gbCfg.Controls.Add((New-Lbl "sec" 170 86 30))

$gbCfg.Controls.Add((New-Lbl "Startup Grace:" 218 86 100))
$numGrace = New-NumUD 322 83 0 120 5
$gbCfg.Controls.Add($numGrace)
$gbCfg.Controls.Add((New-Lbl "sec" 384 86 30))

$btnSaveCfg = New-Btn "Save Config" 10 116 120 28 $BtnBlue
$gbCfg.Controls.Add($btnSaveCfg)

$lblCfgMsg = New-Lbl "" 140 120 455 20
$lblCfgMsg.ForeColor = [System.Drawing.Color]::FromArgb(100, 200, 100)
$gbCfg.Controls.Add($lblCfgMsg)

# Alert suppression schedule row
$gbCfg.Controls.Add((New-Lbl "Suppress alerts:" 10 152 100 20))
$txtSuppressFrom = New-Txt 113 149 60 ""
$txtSuppressFrom.MaxLength = 5
$gbCfg.Controls.Add($txtSuppressFrom)
$gbCfg.Controls.Add((New-Lbl "to" 177 152 20))
$txtSuppressTo = New-Txt 199 149 60 ""
$txtSuppressTo.MaxLength = 5
$gbCfg.Controls.Add($txtSuppressTo)
$lblSuppHint = New-Lbl "(24h HH:mm - blank=disabled; emails only, still logs to file)" 265 152 400 20
$lblSuppHint.ForeColor = [System.Drawing.Color]::FromArgb(85,85,85)
$gbCfg.Controls.Add($lblSuppHint)

# ===========================================================================
# 2. UNIVERSE MONITOR  (y=200, h=100)
# ===========================================================================
$gbMon = New-GB "Universe Monitor" 8 200 684 100
$form.Controls.Add($gbMon)

$lblMonStat = New-Object System.Windows.Forms.Label
$lblMonStat.Text      = "  Stopped"
$lblMonStat.Location  = [System.Drawing.Point]::new(10, 26)
$lblMonStat.Size      = [System.Drawing.Size]::new(200, 26)
$lblMonStat.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblMonStat.ForeColor = [System.Drawing.Color]::FromArgb(200, 65, 65)
$lblMonStat.BackColor = [System.Drawing.Color]::Transparent
$gbMon.Controls.Add($lblMonStat)

$lblMonPID = New-Lbl "" 215 30 160 18
$gbMon.Controls.Add($lblMonPID)

$btnStartMon = New-Btn "Start Monitor" 400 24 150 36 $BtnGreen
$gbMon.Controls.Add($btnStartMon)

$btnStopMon = New-Btn "Stop Monitor" 560 24 116 36 $BtnRed
$btnStopMon.Enabled = $false
$gbMon.Controls.Add($btnStopMon)

$lblMonNote = New-Lbl "Opens in a new PowerShell window." 10 66 400 20
$lblMonNote.ForeColor = [System.Drawing.Color]::FromArgb(75, 75, 75)
$gbMon.Controls.Add($lblMonNote)

# ===========================================================================
# 2b. UNIVERSE HEALTH GRID  (y=310, h=220)
# ===========================================================================
$gbGrid = New-GB "Universe Health" 8 310 684 220
$form.Controls.Add($gbGrid)

# Tile colors: OK=dark green, DROPPED=dark red, OVERLOAD=dark amber, NEVER_SEEN=dark gray
$GridClrOK      = [System.Drawing.Color]::FromArgb(0,   100, 40)
$GridClrDropped = [System.Drawing.Color]::FromArgb(140,  30, 30)
$GridClrOverload= [System.Drawing.Color]::FromArgb(130,  90,  0)
$GridClrNever   = [System.Drawing.Color]::FromArgb( 52,  52, 52)

$pnlGrid = New-Object System.Windows.Forms.Panel
$pnlGrid.Location    = [System.Drawing.Point]::new(8, 22)
$pnlGrid.Size        = [System.Drawing.Size]::new(664, 182)
$pnlGrid.AutoScroll  = $true
$pnlGrid.BackColor   = [System.Drawing.Color]::FromArgb(22, 22, 22)
$pnlGrid.BorderStyle = "FixedSingle"
$gbGrid.Controls.Add($pnlGrid)

$script:healthTiles = [System.Collections.Generic.Dictionary[int, System.Windows.Forms.Label]]::new()

# ===========================================================================
# 3. ART-NET GENERATOR  (y=540, full width, h=330)
# ===========================================================================
$gbGen = New-GB "Art-Net Generator (Test)" 8 540 684 330
$form.Controls.Add($gbGen)

# --- Row 1: Source IP, Dest IP
$gbGen.Controls.Add((New-Lbl "Source IP:" 10 26 72))
$txtSrcIP = New-Combo 85 23 130 ""
$gbGen.Controls.Add($txtSrcIP)
$btnDetectSrc = New-Btn "Detect" 220 22 58 24 $BtnGray
$gbGen.Controls.Add($btnDetectSrc)
$hSrc = New-Lbl "(blank=OS default)" 283 26 120 20
$hSrc.ForeColor = [System.Drawing.Color]::FromArgb(85,85,85)
$gbGen.Controls.Add($hSrc)

$gbGen.Controls.Add((New-Lbl "Dest IP:" 360 26 60))
$txtDstIP = New-Combo 425 23 150 ""
$gbGen.Controls.Add($txtDstIP)

# --- Row 2: Universe count, start universe, PPS
$gbGen.Controls.Add((New-Lbl "# Universes:" 10 56 85))
$numGenCount = New-NumUD 98 53 1 512 24
$gbGen.Controls.Add($numGenCount)

$gbGen.Controls.Add((New-Lbl "Start at:" 170 56 60))
$numGenStart = New-NumUD 233 53 0 32767 1
$gbGen.Controls.Add($numGenStart)

$gbGen.Controls.Add((New-Lbl "Pkt/s:" 305 56 46))
$numGenPPS = New-NumUD 354 53 1 100 10
$gbGen.Controls.Add($numGenPPS)

$btnAllOn  = New-Btn "All ON"  430 52 70 24 $BtnGray
$gbGen.Controls.Add($btnAllOn)
$btnAllOff = New-Btn "All OFF" 506 52 70 24 $BtnGray
$gbGen.Controls.Add($btnAllOff)

$btnBuildGrid = New-Btn "Build Grid" 582 52 90 24 $BtnBlue
$gbGen.Controls.Add($btnBuildGrid)

# --- Universe checkbox grid (scrollable panel)
$pnlUni = New-Object System.Windows.Forms.Panel
$pnlUni.Location   = [System.Drawing.Point]::new(8, 84)
$pnlUni.Size       = [System.Drawing.Size]::new(664, 150)
$pnlUni.AutoScroll = $true
$pnlUni.BackColor  = [System.Drawing.Color]::FromArgb(22, 22, 22)
$pnlUni.BorderStyle = "FixedSingle"
$gbGen.Controls.Add($pnlUni)

$script:uniCheckboxes = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()

function Write-GenControl {
    $enabled = @($script:uniCheckboxes | Where-Object { $_.Checked } | ForEach-Object { [int]$_.Tag })
    try { @{ enabled_universes = $enabled } | ConvertTo-Json | Set-Content $GenControlFile -Encoding UTF8 } catch {}
}

function Build-UniverseGrid {
    # Dispose old checkboxes before clearing - Controls.Clear() does not dispose them
    foreach ($cb in $script:uniCheckboxes) { try { $cb.Dispose() } catch {} }
    $pnlUni.Controls.Clear()
    $script:uniCheckboxes.Clear()
    $script:suppressGenControl = $true  # suppress per-checkbox writes during rebuild
    $count = [int]$numGenCount.Value
    $start = [int]$numGenStart.Value
    $col = 0; $row = 0
    $cw = 74; $ch = 22; $cols = 8
    for ($i = 0; $i -lt $count; $i++) {
        $uNum = $start + $i
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text      = "U$uNum"
        $cb.Checked   = $true
        $cb.Location  = [System.Drawing.Point]::new($col * $cw + 4, $row * $ch + 4)
        $cb.Size      = [System.Drawing.Size]::new($cw - 2, $ch)
        $cb.ForeColor = [System.Drawing.Color]::FromArgb(200,200,200)
        $cb.BackColor = [System.Drawing.Color]::Transparent
        $cb.Tag       = $uNum
        $cb.Add_CheckedChanged({
            if (-not $script:suppressGenControl -and $script:generatorProc -and -not $script:generatorProc.HasExited) {
                Write-GenControl
            }
        })
        $pnlUni.Controls.Add($cb)
        $script:uniCheckboxes.Add($cb)
        $col++
        if ($col -ge $cols) { $col = 0; $row++ }
    }
    $script:suppressGenControl = $false
    if ($script:generatorProc -and -not $script:generatorProc.HasExited) { Write-GenControl }
}

# Start/Stop buttons
$btnStartGen = New-Btn "Start Generator" 8 246 150 36 $BtnGreen
$gbGen.Controls.Add($btnStartGen)

$btnStopGen = New-Btn "Stop Generator" 168 246 150 36 $BtnRed
$btnStopGen.Enabled = $false
$gbGen.Controls.Add($btnStopGen)

$lblGenStatus = New-Lbl "" 330 254 350 20
$lblGenStatus.ForeColor = $TxtGray
$gbGen.Controls.Add($lblGenStatus)

# ===========================================================================
# 4. EMAIL ALERTS  (y=880, h=118)
# ===========================================================================
$gbEmail = New-GB "Email Alerts (Gmail)" 8 880 684 118
$form.Controls.Add($gbEmail)

$chkEmailEn = New-Object System.Windows.Forms.CheckBox
$chkEmailEn.Text      = "Enable email alerts"
$chkEmailEn.Location  = [System.Drawing.Point]::new(10, 22)
$chkEmailEn.Size      = [System.Drawing.Size]::new(165, 22)
$chkEmailEn.ForeColor = $TxtWhite
$chkEmailEn.BackColor = [System.Drawing.Color]::Transparent
$gbEmail.Controls.Add($chkEmailEn)

$gbEmail.Controls.Add((New-Lbl "From:" 10 52 42))
$txtEmailFrom = New-Combo 55 49 200 ""
$gbEmail.Controls.Add($txtEmailFrom)

$gbEmail.Controls.Add((New-Lbl "App Password:" 265 52 90))
$txtEmailPass = New-Object System.Windows.Forms.MaskedTextBox
$txtEmailPass.Location    = [System.Drawing.Point]::new(358, 49)
$txtEmailPass.Size        = [System.Drawing.Size]::new(175, 22)
$txtEmailPass.PasswordChar = [char]0x2022
$txtEmailPass.BackColor   = $DarkInput
$txtEmailPass.ForeColor   = $TxtWhite
$gbEmail.Controls.Add($txtEmailPass)

$gbEmail.Controls.Add((New-Lbl "To:" 10 80 42))
$txtEmailTo = New-Combo 55 77 200 ""
$gbEmail.Controls.Add($txtEmailTo)

$btnTestEmail = New-Btn "Send Test" 265 76 90 24 $BtnGray
$gbEmail.Controls.Add($btnTestEmail)

$lblEmailMsg = New-Lbl "" 365 80 310 20
$lblEmailMsg.ForeColor = [System.Drawing.Color]::FromArgb(100,200,100)
$gbEmail.Controls.Add($lblEmailMsg)

# ===========================================================================
# 5. PUSH NOTIFICATIONS & AUDIO  (y=1008, h=120)
# ===========================================================================
$gbPush = New-GB "Push Notifications & Audio" 8 1008 684 120
$form.Controls.Add($gbPush)

$chkNtfyEn = New-Object System.Windows.Forms.CheckBox
$chkNtfyEn.Text      = "Enable ntfy.sh push"
$chkNtfyEn.Location  = [System.Drawing.Point]::new(10, 22)
$chkNtfyEn.Size      = [System.Drawing.Size]::new(150, 22)
$chkNtfyEn.ForeColor = $TxtWhite
$chkNtfyEn.BackColor = [System.Drawing.Color]::Transparent
$gbPush.Controls.Add($chkNtfyEn)

$gbPush.Controls.Add((New-Lbl "Topic:" 168 24 44))
$txtNtfyTopic = New-Txt 215 21 160 ""
$gbPush.Controls.Add($txtNtfyTopic)

$gbPush.Controls.Add((New-Lbl "Server:" 385 24 48))
$txtNtfyServer = New-Txt 436 21 240 "https://ntfy.sh"
$gbPush.Controls.Add($txtNtfyServer)

$chkAudioEn = New-Object System.Windows.Forms.CheckBox
$chkAudioEn.Text      = "Enable audio alarm"
$chkAudioEn.Location  = [System.Drawing.Point]::new(10, 52)
$chkAudioEn.Size      = [System.Drawing.Size]::new(150, 22)
$chkAudioEn.ForeColor = $TxtWhite
$chkAudioEn.BackColor = [System.Drawing.Color]::Transparent
$gbPush.Controls.Add($chkAudioEn)

$gbPush.Controls.Add((New-Lbl "WAV file:" 168 54 62))
$txtAudioFile = New-Txt 233 51 290 ""
$txtAudioFile.PlaceholderText = "(blank = use system beep)"
$gbPush.Controls.Add($txtAudioFile)

$btnTestNtfy = New-Btn "Test Notification" 10 82 140 28 $BtnGray
$gbPush.Controls.Add($btnTestNtfy)

$lblNtfyMsg = New-Lbl "" 160 86 520 20
$lblNtfyMsg.ForeColor = [System.Drawing.Color]::FromArgb(100,200,100)
$gbPush.Controls.Add($lblNtfyMsg)

# ===========================================================================
# 6. ALERTS LOG  (y=1138, h=230)
# ===========================================================================
$gbLog = New-GB "Alerts Log" 8 1138 684 230
$form.Controls.Add($gbLog)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location   = [System.Drawing.Point]::new(10, 22)
$rtbLog.Size       = [System.Drawing.Size]::new(662, 162)
$rtbLog.BackColor  = [System.Drawing.Color]::FromArgb(16, 16, 16)
$rtbLog.ForeColor  = [System.Drawing.Color]::FromArgb(170, 200, 170)
$rtbLog.Font       = New-Object System.Drawing.Font("Consolas", 8.5)
$rtbLog.ReadOnly   = $true
$rtbLog.ScrollBars = "Vertical"
$rtbLog.WordWrap   = $false
$gbLog.Controls.Add($rtbLog)

$btnRefLog = New-Btn "Refresh" 10 190 100 28 $BtnGray
$gbLog.Controls.Add($btnRefLog)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text      = "Auto-refresh (2 sec)"
$chkAuto.Location  = [System.Drawing.Point]::new(120, 192)
$chkAuto.Size      = [System.Drawing.Size]::new(165, 22)
$chkAuto.Checked   = $true
$chkAuto.ForeColor = $TxtGray
$chkAuto.BackColor = [System.Drawing.Color]::Transparent
$gbLog.Controls.Add($chkAuto)

$btnClearLog = New-Btn "Clear Display" 295 190 118 28 $BtnGray
$gbLog.Controls.Add($btnClearLog)

# ===========================================================================
# Status strip
# ===========================================================================
$strip = New-Object System.Windows.Forms.StatusStrip
$strip.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$stripLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$stripLbl.ForeColor = $TxtGray
$stripLbl.Text      = "Ready"
$strip.Items.Add($stripLbl) | Out-Null
$form.Controls.Add($strip)

# ===========================================================================
# Timers
# ===========================================================================
$timerLog    = New-Object System.Windows.Forms.Timer; $timerLog.Interval    = 2000
$timerStatus = New-Object System.Windows.Forms.Timer; $timerStatus.Interval = 1000

# ===========================================================================
# Functions
# ===========================================================================
function Append-LogColor ([string]$line) {
    $rtbLog.SelectionStart = $rtbLog.TextLength
    if     ($line -match 'ALERT|DROP')        { $rtbLog.SelectionColor = [System.Drawing.Color]::FromArgb(255, 95,  95)  }
    elseif ($line -match 'RECOVERY')          { $rtbLog.SelectionColor = [System.Drawing.Color]::FromArgb(95,  220, 95)  }
    elseif ($line -match 'WARNING|DUPLICATE') { $rtbLog.SelectionColor = [System.Drawing.Color]::FromArgb(255, 210, 50)  }
    elseif ($line -match 'FIRST SEEN')        { $rtbLog.SelectionColor = [System.Drawing.Color]::FromArgb(100, 180, 255) }
    else                                      { $rtbLog.SelectionColor = [System.Drawing.Color]::FromArgb(155, 175, 155) }
    $rtbLog.AppendText("$line`n")
}

function Refresh-Log {
    if (-not (Test-Path $AlertsLog)) {
        if ($rtbLog.TextLength -eq 0) {
            $rtbLog.SelectionColor = [System.Drawing.Color]::FromArgb(85, 85, 85)
            $rtbLog.AppendText("(no alerts log yet - start the monitor to create it)")
        }
        return
    }
    try { $allLines = @(Get-Content $AlertsLog -ErrorAction Stop) }
    catch { return }   # file momentarily locked

    # Only process lines we haven't shown yet
    $newLines = if ($allLines.Count -gt $script:logLineOffset) {
        $allLines[$script:logLineOffset..($allLines.Count - 1)]
    } else { @() }

    if ($newLines.Count -eq 0) { return }

    $script:logLineOffset = $allLines.Count

    # Check if user has scrolled up - don't force scroll if so
    $atBottom = ($rtbLog.SelectionStart -ge $rtbLog.TextLength - 2)

    $rtbLog.SuspendLayout()
    foreach ($line in $newLines) { Append-LogColor $line }
    if ($atBottom) {
        $rtbLog.SelectionStart = $rtbLog.TextLength
        $rtbLog.ScrollToCaret()
    }
    $rtbLog.ResumeLayout()
}

function Write-AlertLog {
    param([string]$Type, [string]$Message)
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$Type] [$ts] $Message"
    try {
        $logsDir = Split-Path $AlertsLog
        if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
        Add-Content -Path $AlertsLog -Value $entry -ErrorAction Stop
    } catch {}
    Refresh-Log
}

# ---------------------------------------------------------------------------
# Health grid - build tiles from expected universe list, refresh from JSON
# ---------------------------------------------------------------------------
function Build-HealthGrid {
    foreach ($lbl in $script:healthTiles.Values) { try { $lbl.Dispose() } catch {} }
    $pnlGrid.Controls.Clear()
    $script:healthTiles.Clear()
    $unis = @()
    try {
        $unis = @($txtUnis.Text -split '[,\s]+' | Where-Object { $_ -ne '' } |
                  ForEach-Object { [int]$_ } | Sort-Object -Unique)
    } catch {}
    if ($unis.Count -eq 0) { return }
    $tileW = 72; $tileH = 52; $cols = 9; $pad = 4
    $col = 0; $row = 0
    foreach ($uni in $unis) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text        = "U$uni`nNONE`n- Hz"
        $lbl.Location    = [System.Drawing.Point]::new($col * ($tileW + $pad) + $pad, $row * ($tileH + $pad) + $pad)
        $lbl.Size        = [System.Drawing.Size]::new($tileW, $tileH)
        $lbl.TextAlign   = [System.Drawing.ContentAlignment]::MiddleCenter
        $lbl.Font        = New-Object System.Drawing.Font("Consolas", 7.5)
        $lbl.ForeColor   = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $lbl.BackColor   = $GridClrNever
        $lbl.BorderStyle = "FixedSingle"
        $pnlGrid.Controls.Add($lbl)
        $script:healthTiles[$uni] = $lbl
        $col++
        if ($col -ge $cols) { $col = 0; $row++ }
    }
}

function Refresh-HealthGrid {
    if (-not (Test-Path $StatusJsonPath)) { return }
    $status = $null
    try {
        $fs     = [System.IO.File]::Open($StatusJsonPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $raw    = $reader.ReadToEnd()
        $reader.Close(); $fs.Dispose()
        $status = $raw | ConvertFrom-Json
    } catch { return }
    if (-not $status -or -not $status.universes) { return }
    foreach ($kv in $script:healthTiles.GetEnumerator()) {
        $uni  = $kv.Key
        $lbl  = $kv.Value
        $uKey = "$uni"
        $uProp = $status.universes.PSObject.Properties | Where-Object { $_.Name -eq $uKey }
        if (-not $uProp) {
            $lbl.BackColor = $GridClrNever
            $lbl.Text      = "U$uni`nNONE`n- Hz"
            continue
        }
        $u     = $uProp.Value
        $state = $u.state
        $hz    = [int]$u.hz
        $lbl.BackColor = switch ($state) {
            'OK'         { $GridClrOK }
            'DROPPED'    { $GridClrDropped }
            'OVERLOAD'   { $GridClrOverload }
            default      { $GridClrNever }
        }
        $stateShort = switch ($state) {
            'OK'         { 'OK' }
            'DROPPED'    { 'DROP' }
            'OVERLOAD'   { 'OVLD' }
            default      { 'NONE' }
        }
        $lbl.Text = "U$uni`n$stateShort`n${hz} Hz"
    }
}

function Update-Status {
    if ($script:monitorProc -and -not $script:monitorProc.HasExited) {
        $lblMonStat.Text      = "  Running"
        $lblMonStat.ForeColor = [System.Drawing.Color]::FromArgb(80, 205, 80)
        $lblMonPID.Text       = "PID $($script:monitorProc.Id)"
        $btnStartMon.Enabled  = $false
        $btnStopMon.Enabled   = $true
    } else {
        if ($script:monitorProc) {
            try { $script:monitorProc.Dispose() } catch {}
            $script:monitorProc = $null
        }
        $lblMonStat.Text      = "  Stopped"
        $lblMonStat.ForeColor = [System.Drawing.Color]::FromArgb(200, 65, 65)
        $lblMonPID.Text       = ""
        $btnStartMon.Enabled  = $true
        $btnStopMon.Enabled   = $false
    }
    if ($script:generatorProc -and -not $script:generatorProc.HasExited) {
        $btnStartGen.Enabled = $false
        $btnStopGen.Enabled  = $true
    } else {
        if ($script:generatorProc) {
            try { $script:generatorProc.Dispose() } catch {}
            $script:generatorProc = $null
        }
        $btnStartGen.Enabled = $true
        $btnStopGen.Enabled  = $false
    }
}

function Populate-Interfaces {
    $cboIface.Items.Clear()
    foreach ($i in (Get-TsharkInterfaces)) { $cboIface.Items.Add($i) | Out-Null }
    # Only restore a previously chosen interface - never auto-select on first boot
    $histId = 0
    if (Test-Path $IPHistoryPath) {
        try {
            $h = Get-Content $IPHistoryPath -Raw | ConvertFrom-Json
            if ($h.last_interface_id) { $histId = [int]$h.last_interface_id }
        } catch {}
    }
    if ($histId -gt 0) {
        for ($i = 0; $i -lt $cboIface.Items.Count; $i++) {
            if ($cboIface.Items[$i] -match "^$histId\b") { $cboIface.SelectedIndex = $i; break }
        }
        # If stored interface no longer exists in tshark list, leave blank so user must choose
    }
    # No history = leave dropdown blank; user must pick before starting monitor
}

function Apply-ConfigToUI {
    Load-Config
    if (-not $script:cfg) { return }
    $m = $script:cfg.monitoring
    $g = $script:cfg.generator
    $e = $script:cfg.email
    $a = $script:cfg.alerts
    if ($m.expected_universes)            { $txtUnis.Text = ($m.expected_universes -join ", ") }
    if ($m.timeout_seconds)               { $numTimeout.Value = [Math]::Max(1,[Math]::Min(120,[int]$m.timeout_seconds)) }
    if ($null -ne $m.startup_grace_seconds) { $numGrace.Value = [Math]::Max(0,[Math]::Min(120,[int]$m.startup_grace_seconds)) }
    if ($m.suppress_start) { $txtSuppressFrom.Text = $m.suppress_start }
    if ($m.suppress_end)   { $txtSuppressTo.Text   = $m.suppress_end }
    if ($g) {
        # Don't set source/dest IP from config - history (Load-IPHistory) handles recall
        if ($g.universe_count)     { $numGenCount.Value = [Math]::Max(1,[Math]::Min(512,[int]$g.universe_count)) }
        if ($g.start_universe)     { $numGenStart.Value = [Math]::Max(0,[Math]::Min(32767,[int]$g.start_universe)) }
        if ($g.packets_per_second) { $numGenPPS.Value   = [Math]::Max(1,[Math]::Min(100,[int]$g.packets_per_second)) }
    }
    if ($e) {
        if ($null -ne $e.enabled) { $chkEmailEn.Checked = [bool]$e.enabled }
        if ($e.app_password -and $e.app_password -notmatch '^xxxx') { $txtEmailPass.Text = $e.app_password }
        # Don't set email_from / email_to from config - history handles recall
    }
    if ($a) {
        if ($null -ne $a.ntfy_enabled)  { $chkNtfyEn.Checked  = [bool]$a.ntfy_enabled }
        if ($a.ntfy_topic)              { $txtNtfyTopic.Text   = $a.ntfy_topic }
        if ($a.ntfy_server)             { $txtNtfyServer.Text  = $a.ntfy_server }
        if ($null -ne $a.audio_enabled) { $chkAudioEn.Checked  = [bool]$a.audio_enabled }
        if ($a.audio_file)              { $txtAudioFile.Text   = $a.audio_file }
    }
    Load-IPHistory
}

# ---------------------------------------------------------------------------
# IP history helpers
# ---------------------------------------------------------------------------
function Prepend-ToHistory {
    param([array]$Arr, [string]$Val)
    if (-not $Val -or $Val.Trim() -eq "") { return [array]$Arr }
    $v    = $Val.Trim()
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add($v) | Out-Null
    foreach ($item in $Arr) { if ($item -ne $v) { $list.Add($item) | Out-Null } }
    if ($list.Count -gt 10) { return @($list[0..9]) }
    return @($list.ToArray())
}

function Get-EmailPassword {
    param([string]$Address)
    if (-not $Address) { return '' }
    # First try ip_history.json per-address passwords
    if (Test-Path $IPHistoryPath) {
        try {
            $raw = Get-Content $IPHistoryPath -Raw | ConvertFrom-Json
            if ($raw.email_passwords) {
                $prop = $raw.email_passwords.PSObject.Properties | Where-Object { $_.Name -eq $Address }
                if ($prop -and $prop.Value) { return $prop.Value }
            }
        } catch {}
    }
    # Fall back to config.json if address matches
    if (Test-Path $ConfigPath) {
        try {
            $cfg2 = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($cfg2.email -and $cfg2.email.from_address -eq $Address -and
                $cfg2.email.app_password -and $cfg2.email.app_password -notmatch '^xxxx') {
                return $cfg2.email.app_password
            }
        } catch {}
    }
    return ''
}

function Load-IPHistory {
    $hist = [ordered]@{ src_ips = @(); dst_ips = @(); email_from = @(); email_to = @() }
    if (Test-Path $IPHistoryPath) {
        try {
            $raw = Get-Content $IPHistoryPath -Raw | ConvertFrom-Json
            if ($raw.src_ips)    { $hist['src_ips']    = @($raw.src_ips) }
            if ($raw.dst_ips)    { $hist['dst_ips']    = @($raw.dst_ips) }
            if ($raw.email_from) { $hist['email_from'] = @($raw.email_from) }
            if ($raw.email_to)   { $hist['email_to']   = @($raw.email_to) }
        } catch {}
    }
    $pairs = @(
        @{ Combo = $txtSrcIP;     Key = 'src_ips' }
        @{ Combo = $txtDstIP;     Key = 'dst_ips' }
        @{ Combo = $txtEmailFrom; Key = 'email_from' }
        @{ Combo = $txtEmailTo;   Key = 'email_to' }
    )
    foreach ($p in $pairs) {
        $cur = $p.Combo.Text
        $p.Combo.Items.Clear()
        foreach ($v in $hist[$p.Key]) { $p.Combo.Items.Add($v) | Out-Null }
        # Restore previous text; if blank, auto-fill from most-recent history entry
        if ($cur -ne '') {
            if ($p.Combo.Text -ne $cur) { $p.Combo.Text = $cur }
        } elseif ($p.Combo.Items.Count -gt 0) {
            $p.Combo.Text = $p.Combo.Items[0]
        }
    }
    # Auto-fill password for the current FROM address
    $fromAddr = $txtEmailFrom.Text.Trim()
    if ($fromAddr) {
        $saved = Get-EmailPassword $fromAddr
        if ($saved) { $txtEmailPass.Text = $saved }
    }
}

# Enumerates all active (Up) non-loopback/non-APIPA IPv4 addresses on this machine.
# Returns array of [pscustomobject]@{ IP; Adapter; Status } sorted to prefer 192.168.50.x.
function Get-LocalAdapterIPs {
    $result = [System.Collections.Generic.List[pscustomobject]]::new()
    $nics   = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
    foreach ($nic in $nics) {
        $status = $nic.OperationalStatus
        foreach ($addr in $nic.GetIPProperties().UnicastAddresses) {
            if ($addr.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $ip = $addr.Address.ToString()
            if ($ip -eq '127.0.0.1')             { continue }
            if ($ip -match '^169\.254\.')         { continue }  # APIPA
            $result.Add([pscustomobject]@{ IP = $ip; Adapter = $nic.Name; Status = $status }) | Out-Null
        }
    }
    # Sort: Up adapters first, then prefer 192.168.50.x transmit range
    return @($result | Sort-Object { if ($_.Status -eq 'Up') { 0 } else { 1 } }, { if ($_.IP -match '^192\.168\.50\.' -and $_.IP -ne '192.168.50.2') { 0 } else { 1 } })
}

function Update-IPHistory {
    param([string]$SrcIP = '', [string]$DstIP = '', [string]$EmailFrom = '', [string]$EmailTo = '', [string]$EmailPass = '', [int]$IfaceId = 0)
    $hist = [ordered]@{ src_ips = @(); dst_ips = @(); email_from = @(); email_to = @(); email_passwords = [ordered]@{}; last_interface_id = 0 }
    if (Test-Path $IPHistoryPath) {
        try {
            $raw = Get-Content $IPHistoryPath -Raw | ConvertFrom-Json
            if ($raw.src_ips)           { $hist['src_ips']           = @($raw.src_ips) }
            if ($raw.dst_ips)           { $hist['dst_ips']           = @($raw.dst_ips) }
            if ($raw.email_from)        { $hist['email_from']        = @($raw.email_from) }
            if ($raw.email_to)          { $hist['email_to']          = @($raw.email_to) }
            if ($raw.last_interface_id) { $hist['last_interface_id'] = [int]$raw.last_interface_id }
            if ($raw.email_passwords) {
                $raw.email_passwords.PSObject.Properties | ForEach-Object {
                    $hist['email_passwords'][$_.Name] = $_.Value
                }
            }
        } catch {}
    }
    $hist['src_ips']    = Prepend-ToHistory $hist['src_ips']    $SrcIP
    $hist['dst_ips']    = Prepend-ToHistory $hist['dst_ips']    $DstIP
    $hist['email_from'] = Prepend-ToHistory $hist['email_from'] $EmailFrom
    $hist['email_to']   = Prepend-ToHistory $hist['email_to']   $EmailTo
    if ($IfaceId -gt 0) { $hist['last_interface_id'] = $IfaceId }
    if ($EmailFrom -and $EmailPass) { $hist['email_passwords'][$EmailFrom] = $EmailPass }
    try { $hist | ConvertTo-Json | Set-Content $IPHistoryPath -Encoding UTF8 } catch {}
    Load-IPHistory
}

# ===========================================================================
# Events
# ===========================================================================
$btnRefIface.Add_Click({
    Populate-Interfaces
    $stripLbl.Text = "Interface list refreshed at $(Get-Date -Format 'HH:mm:ss')"
})

$btnQuickFill.Add_Click({
    $n = [int]$numQuickFill.Value
    $txtUnis.Text = (1..$n) -join ", "
})

$btnSaveCfg.Add_Click({
    $ifaceId = Get-IdFromItem $cboIface.SelectedItem
    try {
        [int[]]$unis = $txtUnis.Text -split '[,\s]+' |
                       Where-Object { $_ -ne "" } |
                       ForEach-Object { [int]$_ }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Invalid universes - enter comma-separated integers, e.g.  0, 1, 2, 3",
            "Config Error", "OK", "Warning") | Out-Null
        return
    }
    # Collect enabled universes from checkboxes
    $enabledUnis = @($script:uniCheckboxes | Where-Object { $_.Checked } | ForEach-Object { [int]$_.Tag })
    Save-Config -InterfaceId $ifaceId -Universes $unis `
                -Timeout ([int]$numTimeout.Value) -Grace ([int]$numGrace.Value) `
                -SuppressStart $txtSuppressFrom.Text.Trim() -SuppressEnd $txtSuppressTo.Text.Trim() `
                -EmailEnabled $chkEmailEn.Checked `
                -SmtpServer "smtp.gmail.com" -SmtpPort 587 -UseSSL $true `
                -FromAddr $txtEmailFrom.Text.Trim() `
                -AppPass $txtEmailPass.Text.Trim() `
                -ToAddr $txtEmailTo.Text.Trim() `
                -NtfyEnabled $chkNtfyEn.Checked `
                -NtfyTopic $txtNtfyTopic.Text.Trim() `
                -NtfyServer $txtNtfyServer.Text.Trim() `
                -AudioEnabled $chkAudioEn.Checked `
                -AudioFile $txtAudioFile.Text.Trim() `
                -GenDestIP $txtDstIP.Text.Trim() -GenSrcIP $txtSrcIP.Text.Trim() `
                -GenCount ([int]$numGenCount.Value) -GenStart ([int]$numGenStart.Value) `
                -GenPPS ([int]$numGenPPS.Value) -GenEnabled $enabledUnis
    $lblCfgMsg.Text = "Saved at $(Get-Date -Format 'HH:mm:ss')"
    $stripLbl.Text  = "Config saved to $ConfigPath"
    Update-IPHistory -SrcIP $txtSrcIP.Text.Trim() -DstIP $txtDstIP.Text.Trim() `
                     -EmailFrom $txtEmailFrom.Text.Trim() -EmailTo $txtEmailTo.Text.Trim()
    Build-HealthGrid    # rebuild tiles if universe list changed
})

$btnStartMon.Add_Click({
    $ifaceId = Get-IdFromItem $cboIface.SelectedItem
    Update-IPHistory -IfaceId $ifaceId  # persist last-used interface for next startup
    $psArgs  = "-NoProfile -ExecutionPolicy Bypass -NoExit " +
               "-File `"$ScriptsPath\monitor-universes.ps1`" -InterfaceId $ifaceId"
    try {
        $script:monitorProc = Start-Process powershell.exe -ArgumentList $psArgs -PassThru
        $stripLbl.Text = "Monitor started on interface $ifaceId (PID $($script:monitorProc.Id))"
        Update-Status
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not start monitor: $_", "Error") | Out-Null
    }
})

$btnStopMon.Add_Click({
    if ($script:monitorProc -and -not $script:monitorProc.HasExited) {
        try { $script:monitorProc.Kill() } catch {}
    }
    if ($script:monitorProc) { try { $script:monitorProc.Dispose() } catch {} }
    $script:monitorProc = $null
    Update-Status
    $stripLbl.Text = "Monitor stopped"
})

$btnDetectSrc.Add_Click({
    $adapters = Get-LocalAdapterIPs
    if ($adapters.Count -eq 0) {
        $stripLbl.Text = 'No active IPv4 adapters found.'
        return
    }
    $cur = $txtSrcIP.Text
    $txtSrcIP.Items.Clear()
    foreach ($a in $adapters) { $txtSrcIP.Items.Add($a.IP) | Out-Null }
    # Auto-select best candidate (first in sorted list = Up + preferred range)
    $best = $adapters[0]
    $txtSrcIP.Text = $best.IP
    $downCount = @($adapters | Where-Object { $_.Status -ne 'Up' }).Count
    $suffix = if ($downCount -gt 0) { "  ($downCount adapter(s) down)" } else { '' }
    $stripLbl.Text = "Source IP detected: $($best.IP) on '$($best.Adapter)' [$($best.Status)]$suffix"
})

$btnBuildGrid.Add_Click({ Build-UniverseGrid })

$btnAllOn.Add_Click({
    $script:suppressGenControl = $true
    foreach ($cb in $script:uniCheckboxes) { $cb.Checked = $true }
    $script:suppressGenControl = $false
    if ($script:generatorProc -and -not $script:generatorProc.HasExited) { Write-GenControl }
})
$btnAllOff.Add_Click({
    $script:suppressGenControl = $true
    foreach ($cb in $script:uniCheckboxes) { $cb.Checked = $false }
    $script:suppressGenControl = $false
    if ($script:generatorProc -and -not $script:generatorProc.HasExited) { Write-GenControl }
})

$btnStartGen.Add_Click({
    $srcIP = $txtSrcIP.Text.Trim()
    $dstIP = $txtDstIP.Text.Trim()
    if (-not $dstIP) { $dstIP = "255.255.255.255" }

    # Pre-validate source IP against local adapters before launching generator
    if ($srcIP -ne '') {
        $adapters = Get-LocalAdapterIPs
        $match    = $adapters | Where-Object { $_.IP -eq $srcIP } | Select-Object -First 1
        if ($null -eq $match) {
            $available = ($adapters | ForEach-Object { "  $($_.IP)  ($($_.Adapter))" }) -join "`n"
            $msg = "Source IP '$srcIP' is not assigned to any local adapter.`n`nAvailable IPs:`n$available`n`nContinue with OS default route instead?"
            $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Source IP Not Found', 'YesNo', 'Warning')
            if ($r -eq 'No') { return }
            $srcIP = ''  # let generator use OS default cleanly
        } elseif ($match.Status -ne 'Up') {
            $msg = "Source IP '$srcIP' is assigned to '$($match.Adapter)' but that adapter is $($match.Status).`n`nCheck the patch cable between Ethernet 2 and Ethernet 3.`n`nContinue with OS default route instead?"
            $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Adapter Down', 'YesNo', 'Warning')
            if ($r -eq 'No') { return }
            $srcIP = ''
        }
    }

    # Collect enabled universe numbers from checkboxes
    $enabledNums = @($script:uniCheckboxes | Where-Object { $_.Checked } | ForEach-Object { [int]$_.Tag })
    if ($enabledNums.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No universes enabled. Check at least one universe.", "Generator", "OK", "Warning") | Out-Null
        return
    }

    $start  = [int]$numGenStart.Value
    $count  = [int]$numGenCount.Value
    $pps    = [int]$numGenPPS.Value

    Update-IPHistory -SrcIP $srcIP -DstIP $dstIP
    Write-GenControl  # write initial live control state before generator reads it
    # Use -UniverseCount/-StartUniverse (simple ints) to avoid [int[]] array binding
    # issues when launching via Start-Process. Pass -EnabledUniverses only when
    # some universes are disabled, using space-separated values (not comma-joined).
    $genArgs = "-UniverseCount $count -StartUniverse $start -DestinationIP $dstIP -PacketsPerSecond $pps -DurationSeconds 0"
    if ($enabledNums.Count -lt $count) {
        $enabledStr = $enabledNums -join ' '
        $genArgs = "$genArgs -EnabledUniverses $enabledStr"
    }
    if ($srcIP -ne "") { $genArgs = "-SourceIP $srcIP $genArgs" }

    $psArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit " +
              "-File `"$ScriptsPath\artnet-generator.ps1`" $genArgs"
    try {
        $script:generatorProc = Start-Process powershell.exe -ArgumentList $psArgs -PassThru
        $lblGenStatus.Text = "Running | $($enabledNums.Count) universes | PID $($script:generatorProc.Id)"
        $stripLbl.Text = "Generator started - $($enabledNums.Count) universes -> $dstIP"
        Update-Status
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not start generator: $_", "Error") | Out-Null
    }
})

$btnStopGen.Add_Click({
    if ($script:generatorProc -and -not $script:generatorProc.HasExited) {
        try { $script:generatorProc.Kill() } catch {}
    }
    if ($script:generatorProc) { try { $script:generatorProc.Dispose() } catch {} }
    $script:generatorProc = $null
    $lblGenStatus.Text = ""
    Update-Status
    $stripLbl.Text = "Generator stopped"
})

$btnTestEmail.Add_Click({
    $from = $txtEmailFrom.Text.Trim()
    $pass = $txtEmailPass.Text.Trim()
    $to   = $txtEmailTo.Text.Trim()
    if (-not $from -or -not $pass -or -not $to) {
        [System.Windows.Forms.MessageBox]::Show("Fill in From, App Password, and To before testing.", "Email Test", "OK", "Warning") | Out-Null
        return
    }
    Update-IPHistory -EmailFrom $from -EmailTo $to -EmailPass $pass
    # Also persist from/password/to into config.json as fallback using string replace
    if (Test-Path $ConfigPath) {
        try {
            $cfgRaw2 = Get-Content $ConfigPath -Raw
            # Escape $ in replacement values to prevent regex backreference expansion
            $safeFrom = $from -replace '\$', '$$$$'
            $safePass = $pass -replace '\$', '$$$$'
            $safeTo   = $to   -replace '\$', '$$$$'
            $cfgRaw2 = $cfgRaw2 -replace '("from_address"\s*:\s*)"[^"]*"', "`${1}`"$safeFrom`""
            $cfgRaw2 = $cfgRaw2 -replace '("app_password"\s*:\s*)"[^"]*"',  "`${1}`"$safePass`""
            $cfgRaw2 = $cfgRaw2 -replace '("to_address"\s*:\s*)"[^"]*"',    "`${1}`"$safeTo`""
            Set-Content $ConfigPath $cfgRaw2 -Encoding UTF8
            Load-Config
        } catch {}
    }
    $lblEmailMsg.Text = "Sending..."
    $form.Refresh()
    $smtp = $null; $msg = $null
    try {
        $smtp = New-Object System.Net.Mail.SmtpClient("smtp.gmail.com", 587)
        $smtp.EnableSsl = $true
        $smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $smtp.UseDefaultCredentials = $false
        $smtp.Credentials = New-Object System.Net.NetworkCredential($from, $pass)
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = $from
        $msg.To.Add($to)
        $msg.Subject = "[Art-Net Monitor] Test Email"
        $msg.Body    = "Test email from Art-Net Monitor Control Panel on $(hostname) at $(Get-Date)."
        $smtp.Send($msg)
        $lblEmailMsg.Text = "Sent OK at $(Get-Date -Format 'HH:mm:ss')"
        $lblEmailMsg.ForeColor = [System.Drawing.Color]::FromArgb(100,200,100)
        Write-AlertLog -Type "INFO" -Message "Test email sent OK: From=$from To=$to"
    } catch {
        $errMsg = $_.Exception.Message
        $lblEmailMsg.Text = "FAILED: $errMsg"
        $lblEmailMsg.ForeColor = [System.Drawing.Color]::FromArgb(255,80,80)
        Write-AlertLog -Type "WARN" -Message "Test email FAILED: $errMsg (From=$from To=$to)"
    } finally {
        if ($msg)  { try { $msg.Dispose()  } catch {} }
        if ($smtp) { try { $smtp.Dispose() } catch {} }
    }
})

$btnTestNtfy.Add_Click({
    $topic  = $txtNtfyTopic.Text.Trim()
    $server = $txtNtfyServer.Text.Trim()
    if (-not $server) { $server = "https://ntfy.sh" }
    if (-not $topic) {
        [System.Windows.Forms.MessageBox]::Show("Enter a Topic before testing.", "ntfy Test", "OK", "Warning") | Out-Null
        return
    }
    $lblNtfyMsg.Text = "Sending..."
    $form.Refresh()
    $wc = $null
    try {
        $url  = "$server/$topic"
        $body = "Test notification from Art-Net Monitor on $(hostname) at $(Get-Date)"
        $wc   = New-Object System.Net.WebClient
        $wc.Headers.Add("Title", "Art-Net Monitor Test")
        $wc.Headers.Add("Priority", "default")
        $wc.Headers.Add("Tags", "test,artnet")
        $wc.UploadString($url, $body) | Out-Null
        $lblNtfyMsg.Text = "Sent OK at $(Get-Date -Format 'HH:mm:ss')"
        $lblNtfyMsg.ForeColor = [System.Drawing.Color]::FromArgb(100,200,100)
        Write-AlertLog -Type "INFO" -Message "Test ntfy notification sent OK: $url"
    } catch {
        $errMsg = $_.Exception.Message
        $lblNtfyMsg.Text = "FAILED: $errMsg"
        $lblNtfyMsg.ForeColor = [System.Drawing.Color]::FromArgb(255,80,80)
        Write-AlertLog -Type "WARN" -Message "Test ntfy notification FAILED: $errMsg (url=$server/$topic)"
    } finally {
        if ($wc) { try { $wc.Dispose() } catch {} }
    }
})

$btnRefLog.Add_Click({
    Refresh-Log
    $stripLbl.Text = "Log refreshed at $(Get-Date -Format 'HH:mm:ss')"
})

$btnClearLog.Add_Click({
    # Advance offset to current file length so auto-refresh won't reload old entries
    if (Test-Path $AlertsLog) {
        try { $script:logLineOffset = @(Get-Content $AlertsLog -ErrorAction Stop).Count } catch {}
    }
    $rtbLog.Clear()
})

$chkAuto.Add_CheckedChanged({
    if ($chkAuto.Checked) { $timerLog.Start() } else { $timerLog.Stop() }
})

$txtEmailFrom.Add_SelectedIndexChanged({
    $addr = $txtEmailFrom.Text.Trim()
    if ($addr) {
        $saved = Get-EmailPassword $addr
        if ($saved) { $txtEmailPass.Text = $saved }
    }
})

$timerLog.Add_Tick({ Refresh-Log; Refresh-HealthGrid })
$timerStatus.Add_Tick({ Update-Status })

$form.Add_FormClosing({
    param($s, $e)
    $monRunning = $script:monitorProc   -and -not $script:monitorProc.HasExited
    $genRunning = $script:generatorProc -and -not $script:generatorProc.HasExited
    if ($monRunning -or $genRunning) {
        $what = @()
        if ($monRunning) { $what += 'Monitor' }
        if ($genRunning) { $what += 'Generator' }
        $result = [System.Windows.Forms.MessageBox]::Show(
            "$($what -join ' and ') still running. Stop and close?",
            "Confirm Close", "YesNo", "Warning")
        if ($result -eq 'No') { $e.Cancel = $true; return }
    }
    # Persist all current field values before teardown so they are recalled on next startup
    $lastIfaceId = Get-IdFromItem $cboIface.SelectedItem
    Update-IPHistory -SrcIP $txtSrcIP.Text.Trim() -DstIP $txtDstIP.Text.Trim() `
                     -EmailFrom $txtEmailFrom.Text.Trim() -EmailTo $txtEmailTo.Text.Trim() `
                     -EmailPass $txtEmailPass.Text.Trim() -IfaceId $lastIfaceId
    # Save email enabled checkbox state directly into config.json via string replace
    if (Test-Path $ConfigPath) {
        try {
            $cfgRaw = Get-Content $ConfigPath -Raw
            $enabledVal = if ($chkEmailEn.Checked) { 'true' } else { 'false' }
            $cfgRaw = $cfgRaw -replace '("enabled"\s*:\s*)(true|false)', "`${1}$enabledVal"
            Set-Content $ConfigPath $cfgRaw -Encoding UTF8
        } catch {}
    }
    $timerLog.Stop()
    $timerStatus.Stop()
    $timerLog.Dispose()
    $timerStatus.Dispose()
    if ($script:monitorProc) {
        try { if (-not $script:monitorProc.HasExited) { $script:monitorProc.Kill() } } catch {}
        try { $script:monitorProc.Dispose() } catch {}
        $script:monitorProc = $null
    }
    if ($script:generatorProc) {
        try { if (-not $script:generatorProc.HasExited) { $script:generatorProc.Kill() } } catch {}
        try { $script:generatorProc.Dispose() } catch {}
        $script:generatorProc = $null
    }
    foreach ($cb in $script:uniCheckboxes) { try { $cb.Dispose() } catch {} }
    $script:uniCheckboxes.Clear()
    foreach ($lbl in $script:healthTiles.Values) { try { $lbl.Dispose() } catch {} }
    $script:healthTiles.Clear()
})

# ===========================================================================
# Initialize
# ===========================================================================
$form.Add_Load({
    Apply-ConfigToUI
    Populate-Interfaces
    Build-UniverseGrid
    Build-HealthGrid
    Refresh-HealthGrid
    # Start offset at end of existing log so old entries are not shown on launch
    if (Test-Path $AlertsLog) {
        try { $script:logLineOffset = @(Get-Content $AlertsLog -ErrorAction Stop).Count } catch {}
    }
    $timerLog.Start()
    $timerStatus.Start()
    $stripLbl.Text = "Ready - monitoring events from this session only"
})

[System.Windows.Forms.Application]::Run($form)
