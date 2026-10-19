$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This installer is only for DJF-Windows.' }
$devices = @(Get-PnpDevice -Class Display | Where-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data -contains 'Root\MttVDD'
})
if ($devices.Count -ne 1) { throw 'Cannot identify the installed console display device.' }
$root = 'C:\ProgramData\DJF-Windows\ConsoleDisplay'
New-Item -ItemType Directory -Force $root | Out-Null
# A SYSTEM task must execute an administrator-owned script.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
    $identity = New-Object Security.Principal.SecurityIdentifier($sid)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
}
Set-Acl $root $acl
Copy-Item (Join-Path $PSScriptRoot 'ConsoleDisplay.ps1') (Join-Path $root 'ConsoleDisplay.ps1') -Force
$arguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$root+'\ConsoleDisplay.ps1" -DeviceId "'+$devices[0].InstanceId+'"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'DJF-Windows-Console-Display' -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force | Out-Null
Start-ScheduledTask -TaskName 'DJF-Windows-Console-Display'
Get-ScheduledTask -TaskName 'DJF-Windows-Console-Display' | Select-Object TaskName,State | ConvertTo-Json -Compress
