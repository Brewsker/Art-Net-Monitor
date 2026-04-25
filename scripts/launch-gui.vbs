Set WShell = CreateObject("WScript.Shell")
WShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\AV-Monitoring\scripts\artnet-monitor-gui.ps1""", 0, False
