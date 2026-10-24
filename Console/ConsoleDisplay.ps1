param([Parameter(Mandatory=$true)][string]$DeviceId)
$ErrorActionPreference = 'Stop'
# Compatibility entry point. The scheduled task runs the native component directly.
& (Join-Path $PSScriptRoot 'ConsoleDisplay.exe') --broker $DeviceId
exit $LASTEXITCODE
