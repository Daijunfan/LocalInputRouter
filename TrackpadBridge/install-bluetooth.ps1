# Run in administrator PowerShell on the physical DJF-Windows.
$ErrorActionPreference = 'Stop'
if (-not ((Get-CimInstance Win32_VideoController).Name -match '5060 Ti')) {
    throw 'This installer is for the physical DJF-Windows with RTX 5060 Ti.'
}
$taskName = 'DJF-Windows-Bluetooth-SSH'
$folder = Join-Path $env:ProgramFiles 'DJF Input Router'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$exe = Join-Path $folder 'BluetoothSSHBridge.exe'
$candidate = Join-Path $folder 'BluetoothSSHBridge.next.exe'
& $env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /out:$candidate (Join-Path $PSScriptRoot 'BluetoothSSHBridge.cs')
if ($LASTEXITCODE -ne 0) { throw 'Bluetooth bridge compilation failed' }
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (Test-Path $exe) { Copy-Item $exe "$exe.previous" -Force }
Move-Item $candidate $exe -Force
$action = New-ScheduledTaskAction -Execute $exe
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask $taskName
