# tshark-test.ps1 — quick diagnostic, run this directly on RADIO PC
$tshark = "C:\Program Files\Wireshark\tshark.exe"
Write-Host "tshark exists: $(Test-Path $tshark)"
Write-Host "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Is Administrator: $isAdmin"
Write-Host ""
Write-Host "Running tshark on interface 8 for 3 seconds..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $tshark
$psi.Arguments = "-i 8 -a duration:3"
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
Write-Host "Exit code: $($proc.ExitCode)"
Write-Host "STDOUT: $stdout"
Write-Host "STDERR: $stderr"
Read-Host "Press Enter to close"
