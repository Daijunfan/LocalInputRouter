$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This installer belongs to the physical DJF-Windows host.' }
$root = 'C:\ProgramData\DJF-Windows\PhysicalKeyboard'
$source = Join-Path $env:LOCALAPPDATA 'DJF-Windows\updates\physical-keyboard-1.0'
$compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$references = @('/r:System.Windows.Forms.dll', '/r:System.Web.Extensions.dll')
& $compiler /nologo /platform:x64 /target:exe /main:PhysicalKeyboardChecks /out:"$source\PhysicalKeyboardChecks.exe" $references "$source\PhysicalKeyboard.cs" "$source\PhysicalKeyboardChecks.cs" "$source\DeleteShortcut.cs"
if ($LASTEXITCODE -ne 0) { throw 'Physical keyboard checks did not compile.' }
& "$source\PhysicalKeyboardChecks.exe"
if ($LASTEXITCODE -ne 0) { throw 'Physical keyboard checks failed.' }
& $compiler /nologo /platform:x64 /target:winexe /out:"$source\PhysicalKeyboard.exe" $references "$source\PhysicalKeyboard.cs"
if ($LASTEXITCODE -ne 0) { throw 'Physical keyboard component did not compile.' }
New-Item -ItemType Directory -Path $root -Force | Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the SYSTEM component directory.' }
$name = 'DJF-Windows-Physical-Keyboard'
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name
    for ($i=0; $i -lt 40 -and (Get-Process PhysicalKeyboard -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
    if (Get-Process PhysicalKeyboard -ErrorAction SilentlyContinue) { throw 'The previous keyboard component has not stopped.' }
}
Copy-Item "$source\PhysicalKeyboard.exe" (Join-Path $root 'PhysicalKeyboard.exe') -Force
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$action = New-ScheduledTaskAction -Execute (Join-Path $root 'PhysicalKeyboard.exe') -Argument "--broker $sid"
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $name
Write-Output 'Installed the independent DJF-Windows physical keyboard session router.'
