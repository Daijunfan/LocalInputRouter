param([Parameter(Mandatory=$true)][string]$DeviceId)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$previous = $null
while ($true) {
    # Physical HDMI/DP monitors replace the headless display. RDP and this
    # driver's own monitor must never count as a physical screen.
    $physical = @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $parent = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Parent').Data
        $parent -ne $DeviceId -and $parent -notlike 'SWD\RemoteDisplayEnum\*'
    }).Count -gt 0
    if ($null -eq $previous -or $physical -ne $previous) {
        $problem = (Get-PnpDeviceProperty -InstanceId $DeviceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
        if ($physical -and $problem -eq 0) { Disable-PnpDevice -InstanceId $DeviceId -Confirm:$false }
        elseif (!$physical -and $problem -eq 22) { Enable-PnpDevice -InstanceId $DeviceId -Confirm:$false }
        $previous = $physical
        $problem = (Get-PnpDeviceProperty -InstanceId $DeviceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
        $state = [pscustomobject]@{physicalMonitor=$physical;virtualDevice=$DeviceId;virtualEnabled=($problem -eq 0);problemCode=$problem;updatedAt=[DateTime]::UtcNow.ToString('o')}
        [IO.File]::WriteAllText((Join-Path $root 'display-status.json'), ($state|ConvertTo-Json -Compress))
    }
    Start-Sleep -Seconds 3
}
