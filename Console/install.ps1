$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This installer is only for DJF-Windows.' }
$root = Join-Path $env:LOCALAPPDATA 'DJF-Windows'
$source = Join-Path $root 'updates\console-1.0'
$msi = Join-Path $source 'TightVNC.msi'
$signature = Get-AuthenticodeSignature $msi
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'GlavSoft') {
    throw 'The official TightVNC installer signature is not valid.'
}
# The password arrives over authenticated SSH stdin, never in the deployment log.
$password = [Console]::In.ReadLine()
if (!$password -or $password.Length -ne 8) { throw 'An eight-character VNC password is required.' }
$options = @(
    '/i', ('"' + $msi + '"'), '/quiet', '/norestart', 'ADDLOCAL=Server',
    'SERVER_REGISTER_AS_SERVICE=1', 'SERVER_ADD_FIREWALL_EXCEPTION=0', 'SERVER_ALLOW_SAS=0',
    'SET_LOOPBACKONLY=1', 'VALUE_OF_LOOPBACKONLY=1',
    'SET_ALLOWLOOPBACK=1', 'VALUE_OF_ALLOWLOOPBACK=1',
    'SET_ACCEPTHTTPCONNECTIONS=1', 'VALUE_OF_ACCEPTHTTPCONNECTIONS=0',
    'SET_RFBPORT=1', 'VALUE_OF_RFBPORT=24805',
    'SET_BLOCKLOCALINPUT=1', 'VALUE_OF_BLOCKLOCALINPUT=0',
    'SET_BLOCKREMOTEINPUT=1', 'VALUE_OF_BLOCKREMOTEINPUT=0',
    'SET_LOCALINPUTPRIORITY=1', 'VALUE_OF_LOCALINPUTPRIORITY=0',
    'SET_ALWAYSSHARED=1', 'VALUE_OF_ALWAYSSHARED=1',
    'SET_DISCONNECTACTION=1', 'VALUE_OF_DISCONNECTACTION=0',
    'SET_REMOVEWALLPAPER=1', 'VALUE_OF_REMOVEWALLPAPER=0',
    'SET_GRABTRANSPARENTWINDOWS=1', 'VALUE_OF_GRABTRANSPARENTWINDOWS=1',
    'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
    'SET_PASSWORD=1', ('VALUE_OF_PASSWORD=' + $password),
    'MsiHiddenProperties=VALUE_OF_PASSWORD'
)
$process = Start-Process msiexec.exe -ArgumentList $options -Wait -PassThru
$password = $null
if ($process.ExitCode -notin 0,3010) { throw "TightVNC installation failed: $($process.ExitCode)" }
Copy-Item (Join-Path $source 'ConsoleDesktop.ps1') (Join-Path $root 'ConsoleDesktop.ps1') -Force
$config = Get-ItemProperty 'HKLM:\SOFTWARE\TightVNC\Server'
if ($config.LoopbackOnly -ne 1 -or $config.BlockLocalInput -ne 0 -or $config.RfbPort -ne 24805) {
    throw 'Console desktop configuration did not match the requested settings.'
}
Get-Service tvnserver | Select-Object Name,Status | ConvertTo-Json -Compress
