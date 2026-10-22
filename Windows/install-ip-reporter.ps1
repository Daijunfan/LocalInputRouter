param(
    [Parameter(Mandatory=$true)][string]$RegistryHost,
    [string]$RegistryUser = 'djf'
)

$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This installer belongs to the physical DJF-Windows host' }
$root = 'C:\ProgramData\DJF-Windows'
$source = Join-Path $PSScriptRoot 'report-windows-ip.ps1'
$target = Join-Path $root 'report-windows-ip.ps1'
foreach ($file in @($source, (Join-Path $root 'ip-reporter-ed25519'), (Join-Path $root 'bupt208-known-hosts'))) {
    if (!(Test-Path -LiteralPath $file)) { throw "Required IP reporter file is missing: $file" }
}
$name = 'DJF-Windows-IP-Reporter'
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name
}
if ($source -ne $target) { Copy-Item -LiteralPath $source -Destination $target -Force }
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument (
    '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}" -RegistryHost "{1}" -RegistryUser "{2}"' -f $target,$RegistryHost,$RegistryUser)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# Start before login, and restart on the next minute even after a normal stop.
$health = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger @((New-ScheduledTaskTrigger -AtStartup), $health) -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $name
[pscustomobject]@{Task=$name;State=[string](Get-ScheduledTask -TaskName $name).State;ScriptSHA=(Get-FileHash $target).Hash} | ConvertTo-Json
