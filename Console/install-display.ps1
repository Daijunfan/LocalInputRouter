$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This installer is only for DJF-Windows.' }
$source = Join-Path $env:LOCALAPPDATA 'DJF-Windows\updates\headless-display'
$driver = Join-Path $source 'driver\VirtualDisplayDriver'
$helper = Join-Path $source 'nefcon\x64\nefconw.exe'
$catalog = Get-AuthenticodeSignature (Join-Path $driver 'mttvdd.cat')
$tool = Get-AuthenticodeSignature $helper
if ($catalog.Status -ne 'Valid' -or $tool.Status -ne 'Valid') { throw 'Display package signatures are not valid.' }
$root = 'C:\VirtualDisplayDriver'
if (Test-Path $root) { throw 'An existing virtual display configuration needs review before installation.' }
New-Item -ItemType Directory $root | Out-Null
Copy-Item ($driver+'\*') $root
[xml]$settings = [IO.File]::ReadAllText((Join-Path $root 'vdd_settings.xml'))
$settings.vdd_settings.global.InnerXml = '<g_refresh_rate>60</g_refresh_rate>'
$settings.vdd_settings.resolutions.InnerXml = '<resolution><width>1920</width><height>1080</height><refresh_rate>60</refresh_rate></resolution><resolution><width>1024</width><height>768</height><refresh_rate>60</refresh_rate></resolution>'
$settings.Save((Join-Path $root 'vdd_settings.xml'))
# Trust this verified package's signing publisher, not a new root certificate.
$certificate = $catalog.SignerCertificate
if (!(Test-Path ('Cert:\LocalMachine\TrustedPublisher\'+$certificate.Thumbprint))) {
    $path = Join-Path $source 'display-publisher.cer'
    [IO.File]::WriteAllBytes($path, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    Import-Certificate -FilePath $path -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
}
$process = Start-Process $helper -ArgumentList @('install',(Join-Path $root 'MttVDD.inf'),'Root\MttVDD') -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Display installation failed: $($process.ExitCode)" }
Get-PnpDevice -Class Display,Monitor -PresentOnly | Select-Object FriendlyName,InstanceId,Status | ConvertTo-Json -Compress
