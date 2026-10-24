param([switch]$Observe)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This installer is only for DJF-Windows.' }
$devices = @(Get-PnpDevice -Class Display | Where-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data -contains 'Root\MttVDD'
})
if ($devices.Count -ne 1) { throw 'Cannot identify the installed console display device.' }
# A locked console has its own timeout; a display execution request alone does
# not replace this policy. Keep the mains-powered recovery screen visible.
if (!$Observe) {
    foreach ($setting in 'VIDEOIDLE', 'VIDEOCONLOCK') {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_VIDEO $setting 0
        if ($LASTEXITCODE -ne 0) { throw "Could not disable AC display timeout: $setting" }
    }
    & powercfg.exe /setactive SCHEME_CURRENT
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply the display power settings.' }
}
$root = 'C:\ProgramData\DJF-Windows\ConsoleDisplay'
$compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$output = Join-Path $PSScriptRoot 'ConsoleDisplay.exe'
& $compiler /nologo /platform:x64 /target:winexe /r:System.Web.Extensions.dll /out:$output (Join-Path $PSScriptRoot 'ConsoleDisplay.cs')
if ($LASTEXITCODE -ne 0) { throw 'Console display component did not compile.' }
New-Item -ItemType Directory -Force $root | Out-Null
# A SYSTEM task must execute an administrator-owned component.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
    $identity = New-Object Security.Principal.SecurityIdentifier($sid)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
}
Set-Acl $root $acl
$name = 'DJF-Windows-Console-Display'
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $name }
# The worker exits when its broker stops. Do not replace a running executable.
for ($i=0; $i -lt 30 -and (Get-Process ConsoleDisplay -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
if (Get-Process ConsoleDisplay -ErrorAction SilentlyContinue) { throw 'The previous display component has not stopped.' }
Copy-Item $output (Join-Path $root 'ConsoleDisplay.exe') -Force
Copy-Item (Join-Path $PSScriptRoot 'ConsoleDisplay.ps1') (Join-Path $root 'ConsoleDisplay.ps1') -Force
$arguments = '--broker "'+$devices[0].InstanceId+'"'
if ($Observe) { $arguments += ' --observe' }
$action = New-ScheduledTaskAction -Execute (Join-Path $root 'ConsoleDisplay.exe') -Argument $arguments
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Trigger $triggers -Force | Out-Null
# Undo the old agent's disabled virtual adapter once. The new agent never toggles adapters.
$disabled = Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -eq $devices[0].InstanceId -and $_.ConfigManagerErrorCode -eq 22 }
if (!$Observe -and $disabled) {
    Enable-PnpDevice -InstanceId $devices[0].InstanceId -Confirm:$false
}
Start-ScheduledTask -TaskName $name
Get-ScheduledTask -TaskName $name | Select-Object TaskName,State | ConvertTo-Json -Compress
