$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'DJF') { throw 'This task belongs to the physical DJF-Windows host' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RouterSession {
    [StructLayout(LayoutKind.Sequential)] struct Session { public int id; public IntPtr name; public int state; }
    [DllImport("wtsapi32.dll", EntryPoint="WTSEnumerateSessionsW", SetLastError=true)]
    static extern bool Enumerate(IntPtr server,int reserved,int version,out IntPtr buffer,out int count);
    [DllImport("wtsapi32.dll", EntryPoint="WTSQuerySessionInformationW", SetLastError=true)]
    static extern bool Query(IntPtr server,int id,int field,out IntPtr buffer,out int count);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
    public static int ActiveRDP() {
        IntPtr buffer; int count;
        if(!Enumerate(IntPtr.Zero,0,1,out buffer,out count))throw new System.ComponentModel.Win32Exception();
        try {
            int size=Marshal.SizeOf(typeof(Session));
            for(int i=0;i<count;i++) {
                var session=(Session)Marshal.PtrToStructure(new IntPtr(buffer.ToInt64()+i*size),typeof(Session));
                string station=Marshal.PtrToStringUni(session.name);
                if(session.state!=0 || !station.StartsWith("RDP-",StringComparison.OrdinalIgnoreCase))continue;
                IntPtr user; int bytes;
                if(!Query(IntPtr.Zero,session.id,5,out user,out bytes))continue;
                try { if(string.Equals(Marshal.PtrToStringUni(user),"djf",StringComparison.OrdinalIgnoreCase))return session.id; }
                finally { WTSFreeMemory(user); }
            }
            return -1;
        } finally { WTSFreeMemory(buffer); }
    }
}
'@
$rdp = [RouterSession]::ActiveRDP()
# Inspect only our receiver. A missing Mac tunnel is a network condition, not a
# reason to restart Windows input. A stale retry log with the tunnel present is.
$clients = @(Get-Process deskflow-core -ErrorAction SilentlyContinue)
$port = Get-NetTCPConnection -LocalPort 24800 -State Listen -ErrorAction SilentlyContinue
if ($port) {
    $connections = @(Get-NetTCPConnection -RemotePort 24800 -State Established -ErrorAction SilentlyContinue)
    $log = Get-Item 'C:\Users\djf\AppData\Local\DJF-Windows\deskflow-client.log' -ErrorAction SilentlyContinue
    foreach ($client in $clients) {
        if ($client.Path -ne 'C:\Program Files\Deskflow\deskflow-core.exe') { continue }
        if (!$client.HasExited -and (Get-Date) - $client.StartTime -gt [TimeSpan]::FromSeconds(20) -and
            !($connections | Where-Object OwningProcess -eq $client.Id) -and $log -and
            (Get-Date) - $log.LastWriteTime -gt [TimeSpan]::FromSeconds(20)) {
            Stop-Process -Id $client.Id -Force
        }
    }
}
if ($rdp -ge 0) {
    # Deskflow's stock service follows the console, which is a different session during RDP.
    if ((Get-Service Deskflow).Status -ne 'Stopped') { Stop-Service Deskflow }
    if (!(Get-Process deskflow-core -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $rdp -and !$_.HasExited })) {
        Start-ScheduledTask -TaskName 'DJF-Windows-RDP-Input'
    }
} else {
    Stop-ScheduledTask -TaskName 'DJF-Windows-RDP-Input'
    if ((Get-Service Deskflow).Status -ne 'Running') { Start-Service Deskflow }
}
# These independent channels must also recover if their receiver exits.
foreach ($name in 'DJF-Windows-Native-Trackpad','DJF-Windows-Voice-Text','DJF-Windows-Clipboard') {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Ready') { Start-ScheduledTask -TaskName $name }
}
[ordered]@{rdpSession=$rdp;service=[string](Get-Service Deskflow).Status;clients=@(Get-Process deskflow-core -ErrorAction SilentlyContinue|Select-Object Id,SessionId)} |
    ConvertTo-Json -Depth 3 | Set-Content 'C:\ProgramData\DJF-Windows\input-session.json' -Encoding UTF8
