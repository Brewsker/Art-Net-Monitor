# tshark-test2.ps1 - Tests the exact field names used by monitor-universes.ps1
# Run for 5 seconds and capture all stdout + stderr to diagnose field errors

$tsharkPath = "C:\Program Files\Wireshark\tshark.exe"

Write-Host "tshark version:"
& $tsharkPath --version | Select-Object -First 1

Write-Host ""
Write-Host "Testing fields one by one..."
Write-Host ""

$fields = @(
    "frame.time_epoch",
    "ip.src",
    "artnet.artdmx.universe",
    "udp.payload"
)

foreach ($field in $fields) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $tsharkPath
    $psi.Arguments              = "-i 8 -s 80 -T fields -e $field -E separator=| -a duration:2"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $status = if ($proc.ExitCode -eq 0) { "OK" } else { "FAIL (exit $($proc.ExitCode))" }
    Write-Host "  Field: $field  ->  $status"
    if ($stderr -match "not a valid|unknown|error" -or $proc.ExitCode -ne 0) {
        Write-Host "    STDERR: $stderr" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Testing all fields together for 3 seconds..."
$psi2 = New-Object System.Diagnostics.ProcessStartInfo
$psi2.FileName               = $tsharkPath
$psi2.Arguments              = "-i 8 -s 80 -T fields -e frame.time_epoch -e ip.src -e artnet.artdmx.universe -e udp.payload -E separator=| -a duration:3"
$psi2.RedirectStandardOutput = $true
$psi2.RedirectStandardError  = $true
$psi2.UseShellExecute        = $false
$psi2.CreateNoWindow         = $true

$proc2 = [System.Diagnostics.Process]::Start($psi2)
$stdout2 = $proc2.StandardOutput.ReadToEnd()
$stderr2 = $proc2.StandardError.ReadToEnd()
$proc2.WaitForExit()

$lines = ($stdout2 -split "`n" | Where-Object { $_ -ne "" }).Count
Write-Host "  Exit code : $($proc2.ExitCode)"
Write-Host "  Lines out : $lines"
Write-Host "  STDERR    : $stderr2"
if ($lines -gt 0) {
    Write-Host "  First line: $(($stdout2 -split "`n")[0])"
}

Read-Host "Press Enter to close"
