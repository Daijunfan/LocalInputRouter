$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'DJF-Windows';$file=Join-Path $root 'ClipboardReceiver.cs';$next=Join-Path $root 'ClipboardReceiver.next.exe';$exe=Join-Path $root 'ClipboardReceiver.exe'
if(!(Test-Path -LiteralPath $file)){throw "Clipboard receiver source is missing: $file"}
$csc=@("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe","$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1)
if(!$csc){throw 'C# compiler was not found'}
& $csc /nologo /target:winexe /platform:x64 /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "/out:$next" $file
if($LASTEXITCODE -ne 0){throw 'Clipboard receiver did not compile'}
$task='DJF-Windows-Clipboard';$existing=Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if($existing){Stop-ScheduledTask -TaskName $task;Get-Process ClipboardReceiver -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $exe}|Stop-Process;Start-Sleep -Milliseconds 300}
Move-Item -LiteralPath $next -Destination $exe -Force
$voice=Get-ScheduledTask -TaskName 'DJF-Windows-Voice-Text' -ErrorAction SilentlyContinue
if($voice){
    $xml=[xml](Export-ScheduledTask -TaskName 'DJF-Windows-Voice-Text')
    $xml.Task.Actions.Exec.Command=[string]$exe
    $xml.Task.Principals.Principal.RunLevel='LeastPrivilege'
    $xml.Task.RegistrationInfo.URI='\DJF-Windows-Clipboard'
    Register-ScheduledTask -TaskName $task -Xml $xml.OuterXml -Force|Out-Null
}else{
    $action=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $root
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
}
Start-ScheduledTask -TaskName $task
[pscustomobject]@{installed=$exe;bytes=(Get-Item $exe).Length;task=$task}|ConvertTo-Json -Compress
