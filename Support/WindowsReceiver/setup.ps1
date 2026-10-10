param(
    [Parameter(Mandatory=$true)][string]$MacPublicKey,
    [string]$MacBluetoothAddress = '',
    [ValidateRange(1,30)][int]$BluetoothChannel = 28
)

$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as administrator, using the Windows account that will receive input.'
}
$parts = $MacPublicKey.Trim() -split '\s+'
if ($parts.Length -lt 2 -or $parts[0] -ne 'ssh-ed25519' -or $parts[1] -notmatch '^[A-Za-z0-9+/=]+$') {
    throw 'Paste the ssh-ed25519 public key shown in the Mac app.'
}
$key = "$($parts[0]) $($parts[1])"
$source = $PSScriptRoot
$userData = Join-Path $env:LOCALAPPDATA 'LocalInputRouter'
$programs = Join-Path $env:LOCALAPPDATA 'Programs\LocalInputRouter'
$systemData = Join-Path $env:ProgramData 'LocalInputRouter'
$deskflow = Join-Path $env:ProgramFiles 'Deskflow\deskflow-core.exe'
if (-not (Test-Path $deskflow)) { throw 'Install Deskflow for Windows before running this setup.' }
New-Item -ItemType Directory -Force -Path $userData,$programs,$systemData | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $compiler)) { throw 'The .NET Framework C# compiler is required.' }

$native = @('NativeTouchpad.cs','NativeScroll.cs','ThreeFingerDesktop.cs','DeleteShortcut.cs','RoutedKeyboard.cs') |
    ForEach-Object { Join-Path $source $_ }
& $compiler /nologo /platform:x64 /target:winexe "/out:$(Join-Path $programs 'TrackpadReceiver.exe')" /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll $native (Join-Path $source 'Receiver.cs')
if ($LASTEXITCODE -ne 0) { throw 'Trackpad receiver compilation failed.' }
& $compiler /nologo /platform:x64 /target:winexe "/out:$(Join-Path $programs 'VoiceReceiver.exe')" /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll (Join-Path $source 'VoiceReceiver.cs') (Join-Path $source 'VoiceText.cs') (Join-Path $source 'VoiceComposition.cs') (Join-Path $source 'VoiceInputActivity.cs')
if ($LASTEXITCODE -ne 0) { throw 'Voice receiver compilation failed.' }
& $compiler /nologo /platform:x64 /target:winexe "/out:$(Join-Path $programs 'ClipboardReceiver.exe')" /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll (Join-Path $source 'ClipboardReceiver.cs')
if ($LASTEXITCODE -ne 0) { throw 'Clipboard receiver compilation failed.' }
& $compiler /nologo /platform:x64 /target:winexe "/out:$(Join-Path $programs 'BluetoothSSHBridge.exe')" (Join-Path $source 'BluetoothSSHBridge.cs')
if ($LASTEXITCODE -ne 0) { throw 'Bluetooth bridge compilation failed.' }

$feature = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
$installedNow = $feature.State -ne 'Installed'
if ($installedNow) { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null }
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if ($installedNow) {
    Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
}
if (-not (Get-NetFirewallRule -DisplayName 'Local Input Router SSH (local subnet)' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Local Input Router SSH (local subnet)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -Profile Any -RemoteAddress LocalSubnet | Out-Null
}
$authorized = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
if (-not (Test-Path $authorized)) { New-Item -ItemType File -Path $authorized -Force | Out-Null }
if (-not (@(Get-Content $authorized | Where-Object { $_.StartsWith($key) }).Count)) {
    [IO.File]::AppendAllText($authorized,$key+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}
& icacls.exe $authorized /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null

$client = @"
[core]
computerName=Local-Router-Windows
coreMode=1
processMode=0
port=24900
[client]
remoteHost=127.0.0.1
languageSync=false
dynamicConnectionInterval=true
[security]
tlsEnabled=false
[log]
level=INFO
toFile=false
"@
[IO.File]::WriteAllText((Join-Path $userData 'deskflow-client.ini'),$client,[Text.UTF8Encoding]::new($false))
$user = "$env:USERDOMAIN\$env:USERNAME"
$userPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$logon = New-ScheduledTaskTrigger -AtLogOn -User $user
$deskflowArgs = 'client --new-instance --settings "' + (Join-Path $userData 'deskflow-client.ini') + '"'
$tasks = @(
    [pscustomobject]@{ Name='LocalInputRouter-Deskflow'; Exe=$deskflow; Args=$deskflowArgs },
    [pscustomobject]@{ Name='LocalInputRouter-Trackpad'; Exe=(Join-Path $programs 'TrackpadReceiver.exe'); Args='' },
    [pscustomobject]@{ Name='LocalInputRouter-Voice'; Exe=(Join-Path $programs 'VoiceReceiver.exe'); Args='' },
    [pscustomobject]@{ Name='LocalInputRouter-Clipboard'; Exe=(Join-Path $programs 'ClipboardReceiver.exe'); Args='' }
)
foreach ($task in $tasks) {
    $name = $task.Name
    $old = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($old) { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue }
    $action = if ($task.Args) { New-ScheduledTaskAction -Execute $task.Exe -Argument $task.Args }
              else { New-ScheduledTaskAction -Execute $task.Exe }
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $logon -Principal $userPrincipal -Force | Out-Null
    if ($name -eq 'LocalInputRouter-Deskflow') { Start-ScheduledTask -TaskName $name }
}
if ($MacBluetoothAddress) {
    $address = $MacBluetoothAddress.Replace(':','').Replace('-','')
    if ($address -notmatch '^[0-9A-Fa-f]{12}$') { throw 'Invalid Mac Bluetooth address.' }
    [IO.File]::WriteAllLines((Join-Path $systemData 'bluetooth-peer.txt'),@($address,$BluetoothChannel),[Text.UTF8Encoding]::new($false))
    $existing = Get-ScheduledTask -TaskName 'LocalInputRouter-Bluetooth' -ErrorAction SilentlyContinue
    if ($existing) { Stop-ScheduledTask -TaskName 'LocalInputRouter-Bluetooth' -ErrorAction SilentlyContinue }
    $action = New-ScheduledTaskAction -Execute (Join-Path $programs 'BluetoothSSHBridge.exe')
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'LocalInputRouter-Bluetooth' -Action $action -Trigger $trigger -Principal $system -Force | Out-Null
    Start-ScheduledTask -TaskName 'LocalInputRouter-Bluetooth'
}
Write-Output 'Copy this Windows SSH fingerprint to compare with the Mac app:'
& (Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe') -lf (Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub') -E sha256
Write-Output "Windows username: $env:USERNAME; computer name: $env:COMPUTERNAME"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } | Select-Object InterfaceAlias,IPAddress
