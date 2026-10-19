$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This command is only for DJF-Windows.' }
if ((Get-Service tvnserver).Status -ne 'Running') { throw 'The console desktop service is not running.' }
Add-Type @'
using System.Runtime.InteropServices;
public static class DJFConsoleSession {
    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();
}
'@
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$sessions = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object {
    $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
    if ($owner.Sid -eq $sid) { $_.SessionId }
} | Sort-Object -Unique)
$previous = [DJFConsoleSession]::WTSGetActiveConsoleSessionId()
if ($sessions.Count -gt 1) { throw 'Cannot identify a single desktop belonging to the SSH account.' }
if ($sessions.Count -eq 0) {
    # Before sign-in, share the existing console login screen.
    $session = $previous
} else { $session = [uint32]$sessions[0] }
if ($session -ne $previous) {
    # Reconnect the existing desktop; do not log off or start another user session.
    $transfer = & "$env:WINDIR\System32\tscon.exe" $session /dest:console 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot reconnect the existing desktop to the console: $transfer" }
}
$console = [DJFConsoleSession]::WTSGetActiveConsoleSessionId()
if ($console -ne $session) { throw 'The physical console did not receive the existing desktop.' }
[pscustomobject]@{host=$env:COMPUTERNAME;sessionId=$session;consoleId=$console;transferred=($previous -ne $console)} |
    ConvertTo-Json -Compress
