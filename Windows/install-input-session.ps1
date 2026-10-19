$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This installer belongs to the physical DJF-Windows host' }
$root = 'C:\ProgramData\DJF-Windows'
$backup = Join-Path $root 'rdp-input-before-20261010'
if (!(Test-Path $backup)) {
    New-Item -ItemType Directory -Path $backup | Out-Null
    Get-Service Deskflow | Select-Object Name,Status,StartType | ConvertTo-Json | Set-Content (Join-Path $backup 'service.json')
    Copy-Item (Join-Path $root 'deskflow-client.ini') $backup
}
$launch = 'while($true){$p=Start-Process ''C:\Program Files\Deskflow\deskflow-core.exe'' -ArgumentList ''client --new-instance --settings "C:\ProgramData\DJF-Windows\deskflow-client.ini"'' -WindowStyle Hidden -PassThru; while(!$p.HasExited){Start-Sleep -Milliseconds 250}; $p.Dispose(); Start-Sleep -Milliseconds 250}'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
$client = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
if (Get-ScheduledTask -TaskName 'DJF-Windows-RDP-Input' -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName 'DJF-Windows-RDP-Input'
}
$user = New-ScheduledTaskPrincipal -UserId 'DJF\djf' -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'DJF-Windows-RDP-Input' -Action $client -Principal $user -Settings $settings -Force | Out-Null

$class = Get-CimClass -Namespace 'root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
$event = New-CimInstance -CimClass $class -ClientOnly -Property @{
    Enabled = $true
    Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"><Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">*[System[(EventID=21 or EventID=24 or EventID=25)]]</Select></Query></QueryList>'
    Delay = 'PT2S'
}
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\DJF-Windows\input-session.ps1"'
$system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$health = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$triggers = @((New-ScheduledTaskTrigger -AtStartup), $event, $health)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Queue
Register-ScheduledTask -TaskName 'DJF-Windows-Input-Session' -Action $action -Principal $system -Settings $settings -Trigger $triggers -Force | Out-Null
Start-ScheduledTask -TaskName 'DJF-Windows-Input-Session'
Write-Output 'Installed desktop session selection for RDP and physical console'
