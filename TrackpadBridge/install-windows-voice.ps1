$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'DJF-Windows'
$source=Join-Path $root 'updates\voice-1.0.1'
$compiler="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$wpf="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\WPF"
$references=@('/r:System.Web.Extensions.dll','/r:System.Windows.Forms.dll',"/r:$wpf\UIAutomationClient.dll","/r:$wpf\UIAutomationTypes.dll","/r:$wpf\WindowsBase.dll")
$files=@('VoiceReceiver.cs','VoiceComposition.cs','VoiceInputActivity.cs','VoiceText.cs') | ForEach-Object {Join-Path $source $_}
& $compiler /nologo /platform:x64 /target:exe /out:"$source\VoiceChecks.exe" $references $files
if($LASTEXITCODE -ne 0){throw 'Voice checks did not compile'}
& "$source\VoiceChecks.exe" --test
if($LASTEXITCODE -ne 0){throw 'Voice delta checks failed'}
& $compiler /nologo /platform:x64 /target:winexe /out:"$source\VoiceReceiver.exe" $references $files
if($LASTEXITCODE -ne 0){throw 'Voice receiver did not compile'}
Stop-ScheduledTask -TaskName 'DJF-Windows-Voice-Text'
for($i=0;$i -lt 30 -and (Get-Process VoiceReceiver -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 100}
if(Get-Process VoiceReceiver -ErrorAction SilentlyContinue){throw 'Old voice receiver is still running'}
Copy-Item (Join-Path $source 'VoiceReceiver.exe') (Join-Path $root 'VoiceReceiver.exe') -Force
Start-ScheduledTask -TaskName 'DJF-Windows-Voice-Text'
for($i=0;$i -lt 50 -and !(Get-Process VoiceReceiver -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 200}
[pscustomobject]@{HostName=$env:COMPUTERNAME;VoiceProcess=@(Get-Process VoiceReceiver|Select-Object Id,SessionId);Status=([IO.File]::ReadAllText((Join-Path $root 'voice-status.json'))|ConvertFrom-Json)} | ConvertTo-Json -Depth 4 -Compress
