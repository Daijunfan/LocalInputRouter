$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'DJF-Windows'
$source=Join-Path $root 'updates\receiver-1.1.5'
$compiler="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$files=@('NativeTouchpad.cs','NativeScroll.cs','ThreeFingerDesktop.cs','DeleteShortcut.cs','RoutedKeyboard.cs') | ForEach-Object {Join-Path $source $_}
& $compiler /nologo /platform:x64 /target:exe /out:"$source\WindowsBindingsChecks.exe" /r:System.Windows.Forms.dll $files (Join-Path $source 'WindowsBindingsChecks.cs')
if($LASTEXITCODE -ne 0){throw 'Windows binding checks did not compile'}
& "$source\WindowsBindingsChecks.exe"
if($LASTEXITCODE -ne 0){throw 'Windows binding checks failed'}
Stop-ScheduledTask -TaskName 'DJF-Windows-Native-Trackpad'
for($i=0;$i -lt 20 -and (Get-Process TrackpadReceiver -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 100}
if(Get-Process TrackpadReceiver -ErrorAction SilentlyContinue){throw 'Old receiver is still running'}
& $compiler /nologo /platform:x64 /target:winexe /out:"$source\TrackpadReceiver.exe" /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll $files (Join-Path $source 'Receiver.cs')
if($LASTEXITCODE -ne 0){throw 'Receiver did not compile'}
$exe=Join-Path $root 'TrackpadReceiver.exe'
try { Copy-Item "$source\TrackpadReceiver.exe" $exe -Force }
catch [UnauthorizedAccessException] { $exe=Join-Path $source 'TrackpadReceiver.exe' }
$action=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $root
Set-ScheduledTask -TaskName 'DJF-Windows-Native-Trackpad' -Action $action | Out-Null
Start-ScheduledTask -TaskName 'DJF-Windows-Native-Trackpad'
$status=$null
for($i=0;$i -lt 50;$i++){
    $process=Get-Process TrackpadReceiver -ErrorAction SilentlyContinue
    try{$status=[IO.File]::ReadAllText((Join-Path $root 'trackpad-status.json')) | ConvertFrom-Json}catch{$status=$null}
    if($process -and $status.ready -and $status.version -eq '1.1.5' -and $status.pid -in $process.Id){break}
    Start-Sleep -Milliseconds 200
}
if(!$process -or !$status.ready -or $status.version -ne '1.1.5' -or $status.pid -notin $process.Id){throw 'Updated native receiver did not become ready'}
[pscustomobject]@{Installed=$exe;Process=@($process | Select-Object Id,SessionId);Status=$status} | ConvertTo-Json -Depth 4
