$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This migration is only for DJF-Windows.' }
$key = 'HKLM:\SOFTWARE\TightVNC\Server'
$before = (Get-ItemProperty $key).RfbPort
if ($before -notin 24805,24905) { throw 'The console service uses an unexpected port; no change was made.' }
if ($before -ne 24905) {
    Set-ItemProperty $key -Name RfbPort -Value 24905
    Restart-Service tvnserver
}
$listener = Get-NetTCPConnection -LocalPort 24905 -State Listen -ErrorAction SilentlyContinue
if (!$listener) { throw 'The console video listener did not start on 24905.' }
[pscustomobject]@{before=$before;port=24905;service=[string](Get-Service tvnserver).Status} | ConvertTo-Json -Compress
