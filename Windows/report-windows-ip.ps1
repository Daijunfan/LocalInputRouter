param(
    [Parameter(Mandatory=$true)][string]$RegistryHost,
    [string]$RegistryUser = 'djf'
)

$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This reporter belongs to the physical DJF-Windows host' }
$root = 'C:\ProgramData\DJF-Windows'
$key = Join-Path $root 'ip-reporter-ed25519'
$knownHosts = Join-Path $root 'bupt208-known-hosts'
$statusFile = Join-Path $root 'ip-reporter-status.json'
$gpu = ''
$lastSignature = $null
$lastSuccess = ''
$sinceSuccess = [Diagnostics.Stopwatch]::StartNew()

while ($true) {
    try {
        # WMI may not be ready at boot; initialization must retry with the network.
        if (!$gpu) {
            $gpu = ((Get-CimInstance Win32_VideoController -OperationTimeoutSec 5).Name |
                Where-Object { $_ -like '*5060 Ti*' }) -join ', '
            if (!$gpu) { throw 'RTX 5060 Ti identification is not available yet' }
        }
        $ips = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object {
                $_.Address.AddressFamily -eq 'InterNetwork' -and
                ![Net.IPAddress]::IsLoopback($_.Address) -and
                $_.Address.ToString() -notlike '169.254.*'
            } | ForEach-Object { $_.Address.ToString() } | Sort-Object -Unique)
        $signature = $ips -join ','
        if ($signature -ne $lastSignature -or $sinceSuccess.Elapsed.TotalSeconds -ge 30) {
            $payload = @{name='DJF-Windows';hostname=$env:COMPUTERNAME;gpu=$gpu;ips=$ips} | ConvertTo-Json -Compress
            $message = 'DJFWindowsIP ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
            $ssh = [Diagnostics.Process]::new()
            try {
                $ssh.StartInfo.FileName = "$env:WINDIR\System32\OpenSSH\ssh.exe"
                $ssh.StartInfo.Arguments = '-T -i "{0}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile={1}" -o ConnectionAttempts=1 -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=1 "{2}@{3}" "{4}"' -f $key,$knownHosts,$RegistryUser,$RegistryHost,$message
                $ssh.StartInfo.UseShellExecute = $false
                $ssh.StartInfo.CreateNoWindow = $true
                $ssh.StartInfo.RedirectStandardOutput = $true
                $ssh.StartInfo.RedirectStandardError = $true
                if (!$ssh.Start()) { throw 'Could not start the IP report connection' }
                $output = $ssh.StandardOutput.ReadToEndAsync()
                $errors = $ssh.StandardError.ReadToEndAsync()
                if (!$ssh.WaitForExit(15000)) {
                    $ssh.Kill()
                    throw 'IP report connection timed out'
                }
                $response = $output.Result.Trim()
                if ($ssh.ExitCode -ne 0 -or $response -ne 'OK') {
                    throw ('IP report was not acknowledged: ' + $errors.Result.Trim() + ' ' + $response)
                }
            } finally { $ssh.Dispose() }
            $lastSignature = $signature
            $lastSuccess = [DateTime]::UtcNow.ToString('o')
            $sinceSuccess.Restart()
            @{version='1.1';pid=$PID;time=$lastSuccess;success=$true;ips=$ips;response=$response;lastSuccessAt=$lastSuccess} |
                ConvertTo-Json -Compress | Set-Content $statusFile -Encoding UTF8
        }
    } catch {
        # A failed heartbeat must retry even if the interface addresses did not change.
        $lastSignature = $null
        @{version='1.1';pid=$PID;time=[DateTime]::UtcNow.ToString('o');success=$false;lastSuccessAt=$lastSuccess;error=$_.Exception.Message} |
            ConvertTo-Json -Compress | Set-Content $statusFile -Encoding UTF8
    }
    Start-Sleep -Seconds 5
}
