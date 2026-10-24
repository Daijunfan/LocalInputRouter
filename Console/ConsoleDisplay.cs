// Keep attached physical outputs usable without disabling the headless display.
// DisplayConfig must run in the physical console, including before user sign-in.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

static class ConsoleDisplayNative {
    [StructLayout(LayoutKind.Sequential)] public struct Luid { public uint low; public int high; }
    [StructLayout(LayoutKind.Sequential)] public struct Source { public Luid adapter; public uint id,mode,status; }
    [StructLayout(LayoutKind.Sequential)] public struct Target {
        public Luid adapter; public uint id,mode,technology,rotation,scaling,numerator,denominator,scan;
        public int available; public uint status;
    }
    [StructLayout(LayoutKind.Sequential)] public struct DisplayPath { public Source source; public Target target; public uint flags; }
    // DISPLAYCONFIG_MODE_INFO's union is 48 bytes; source mode starts at byte 16.
    [StructLayout(LayoutKind.Explicit,Size=64)] public struct Mode {
        [FieldOffset(0)] public uint type; [FieldOffset(4)] public uint id; [FieldOffset(8)] public Luid adapter;
        [FieldOffset(16)] public uint width; [FieldOffset(20)] public uint height;
        [FieldOffset(28)] public int x; [FieldOffset(32)] public int y;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Header { public uint type,size; public Luid adapter; public uint id; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct AdapterName {
        public Header header; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string path;
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct TargetName {
        public Header header; public uint flags,technology; public ushort manufacturer,product; public uint connector;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)] public string name;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string path;
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title; public int x,y,width,height,xChars,yChars,fill,flags;
        public short show,reservedSize; public IntPtr reservedData,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential,Pack=1)] struct Privilege { public int count; public long luid; public int attributes; }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags,out uint paths,out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags,ref uint paths,[Out] DisplayPath[] pathArray,ref uint modes,[Out] Mode[] modeArray,IntPtr topology);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint paths,DisplayPath[] pathArray,uint modes,Mode[] modeArray,uint flags);
    [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")] static extern int AdapterInfo(ref AdapterName info);
    [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")] static extern int TargetInfo(ref TargetName info);
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr token,uint access,IntPtr attrs,int level,int type,out IntPtr duplicate);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetTokenInformation(IntPtr token,int field,ref int value,int size);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out long luid);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref Privilege privileges,int size,IntPtr previous,IntPtr needed);
    [DllImport("advapi32.dll",EntryPoint="CreateProcessAsUserW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateUserProcess(IntPtr token,string application,StringBuilder command,IntPtr processAttrs,IntPtr threadAttrs,bool inherit,uint flags,IntPtr env,string directory,ref Startup startup,out ProcessInfo process);
    static void Check(bool success) { if(!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static void CheckCode(int code) { if(code!=0) throw new Win32Exception(code); }
    public static void KeepDisplayOn(bool attached) {
        // A locked console can otherwise power off while all input goes to RDP.
        // This is a process-owned display request, not a power-plan or sleep-policy edit.
        if(SetThreadExecutionState(0x80000000u | (attached?2u:0u))==0) throw new InvalidOperationException("Cannot maintain the attached console display.");
    }
    public static Process StartWorker(int session,string arguments) {
        // Same SYSTEM token/session handoff used by PhysicalKeyboard.cs; no user password or logon required.
        IntPtr own,token; Check(OpenProcessToken(Process.GetCurrentProcess().Handle,0x2A,out own));
        try {
            long luid; Check(LookupPrivilegeValue(null,"SeTcbPrivilege",out luid));
            var privilege=new Privilege{count=1,luid=luid,attributes=2}; Check(AdjustTokenPrivileges(own,false,ref privilege,0,IntPtr.Zero,IntPtr.Zero));
            Check(DuplicateTokenEx(own,0x02000000,IntPtr.Zero,2,1,out token));
            try {
                Check(SetTokenInformation(token,12,ref session,4));
                string app=Process.GetCurrentProcess().MainModule.FileName;
                var startup=new Startup{cb=Marshal.SizeOf(typeof(Startup)),desktop=@"winsta0\Winlogon",flags=1,show=0}; ProcessInfo process;
                Check(CreateUserProcess(token,app,new StringBuilder("\""+app+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,Path.GetDirectoryName(app),ref startup,out process));
                try { return Process.GetProcessById(process.pid); } finally { CloseHandle(process.thread); CloseHandle(process.process); }
            } finally { CloseHandle(token); }
        } finally { CloseHandle(own); }
    }
    public static DisplayPath[] Query(out Mode[] modes) {
        // A hotplug can change the required buffer sizes between these two calls.
        while(true) {
            uint paths,count; CheckCode(GetDisplayConfigBufferSizes(1,out paths,out count));
            var result=new DisplayPath[paths]; modes=new Mode[count];
            int code=QueryDisplayConfig(1,ref paths,result,ref count,modes,IntPtr.Zero);
            if(code==122) continue;
            CheckCode(code); Array.Resize(ref result,(int)paths); Array.Resize(ref modes,(int)count); return result;
        }
    }
    public static string Adapter(DisplayPath path) {
        var info=new AdapterName{header=new Header{type=4,size=(uint)Marshal.SizeOf(typeof(AdapterName)),adapter=path.target.adapter}};
        CheckCode(AdapterInfo(ref info)); return info.path;
    }
    public static string Name(DisplayPath path) {
        var info=new TargetName{header=new Header{type=2,size=(uint)Marshal.SizeOf(typeof(TargetName)),adapter=path.target.adapter,id=path.target.id}};
        CheckCode(TargetInfo(ref info)); return info.name;
    }
    public static void Apply(DisplayPath[] paths,Mode[] modes,bool force=false) {
        const uint supplied=0x20,validate=0x40,apply=0x80,save=0x200,allowChanges=0x400;
        CheckCode(SetDisplayConfig((uint)paths.Length,paths,(uint)modes.Length,modes,supplied|validate|allowChanges));
        CheckCode(SetDisplayConfig((uint)paths.Length,paths,(uint)modes.Length,modes,supplied|apply|save|allowChanges|(force?0x1100u:0u)));
    }
}

static class ConsoleDisplayPolicy {
    public static string Target(ConsoleDisplayNative.DisplayPath path) { return path.target.adapter.high+":"+path.target.adapter.low+":"+path.target.id; }
    static string Source(ConsoleDisplayNative.DisplayPath path) { return path.source.adapter.high+":"+path.source.adapter.low+":"+path.source.id; }
    public static bool Virtual(string adapter,string device) { return adapter.IndexOf(device.Replace('\\','#')+"#",StringComparison.OrdinalIgnoreCase)>=0; }
    public static bool Physical(string adapter,string device) {
        return !Virtual(adapter,device) && adapter.IndexOf("RemoteDisplayEnum",StringComparison.OrdinalIgnoreCase)<0;
    }
    public static ConsoleDisplayNative.DisplayPath[] Repair(ConsoleDisplayNative.DisplayPath[] paths,HashSet<string> physical) {
        // Preserve every active path and its mode indexes, including the virtual screen.
        var selected=paths.Where(p=>(p.flags&1)!=0 && p.target.available!=0).ToList();
        var targets=new HashSet<string>(selected.Select(Target));
        var sources=new HashSet<string>(selected.Select(Source));
        foreach(var path in paths) {
            if(path.target.available==0 || targets.Contains(Target(path))) continue;
            if(!physical.Contains(Target(path)) && selected.Count!=0) continue;
            if(sources.Contains(Source(path))) continue;
            var added=path; added.flags|=1; added.source.mode=uint.MaxValue; added.target.mode=uint.MaxValue;
            added.target.rotation=1; added.target.scaling=128; added.target.numerator=0; added.target.denominator=0; added.target.scan=0;
            selected.Add(added); targets.Add(Target(path)); sources.Add(Source(path));
        }
        return selected.ToArray();
    }
    public static bool PhysicalPrimary(ConsoleDisplayNative.DisplayPath[] paths,ConsoleDisplayNative.Mode[] modes,HashSet<string> physical) {
        var candidates=paths.Where(p=>physical.Contains(Target(p)) && p.source.mode<modes.Length && modes[p.source.mode].type==1).ToArray();
        if(candidates.Length==0 || candidates.Any(p=>modes[p.source.mode].x==0 && modes[p.source.mode].y==0)) return false;
        var primary=modes[candidates[0].source.mode];
        // Put the login/lock screen on hardware. Relative layout and virtual modes stay intact.
        for(int i=0;i<modes.Length;i++) if(modes[i].type==1) { modes[i].x-=primary.x; modes[i].y-=primary.y; }
        return true;
    }
}

static class ConsoleDisplay {
    static readonly string Root=Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static string Role="broker";
    static void Status(string file,object value) { File.WriteAllText(Path.Combine(Root,file+".json"),Json.Serialize(value)); }
    static void Stop(ref Process child) {
        if(child==null) return;
        if(!child.HasExited) { child.Kill(); child.WaitForExit(2000); }
        child.Dispose(); child=null;
    }
    static int Main(string[] args) {
        try {
            if(Environment.MachineName!="DJF" || !WindowsIdentity.GetCurrent().IsSystem) throw new InvalidOperationException("Only the DJF-Windows SYSTEM display task may run this component.");
            if(args.Length>=2 && args[0]=="--broker") { Broker(args[1],args.Contains("--observe")); return 0; }
            if(args.Length>=3 && args[0]=="--worker") { Role="worker"; Worker(int.Parse(args[1]),args[2],args.Contains("--observe")); return 0; }
            return 2;
        } catch(Exception error) { Status(Role,new{ready=false,error=error.ToString(),updatedAt=DateTime.UtcNow.ToString("o")}); return 1; }
    }
    static void Broker(string device,bool observe) {
        using(var mutex=new Mutex(false,@"Global\DJF.ConsoleDisplay")) {
            if(!mutex.WaitOne(0)) return;
            Process child=null; int console=-1;
            try {
                while(true) {
                    try {
                        int next=(int)ConsoleDisplayNative.WTSGetActiveConsoleSessionId();
                        if(next!=console || (child!=null && child.HasExited)) { Stop(ref child); console=next; }
                        if(console>0 && child==null) child=ConsoleDisplayNative.StartWorker(console,"--worker "+Process.GetCurrentProcess().Id+" \""+device+"\""+(observe?" --observe":""));
                        Status("broker",new{ready=child!=null,consoleSession=console,workerPID=child==null?0:child.Id,pid=Process.GetCurrentProcess().Id,observe=observe,updatedAt=DateTime.UtcNow.ToString("o")});
                    } catch(Exception error) { Stop(ref child); Status("broker",new{ready=false,error=error.Message,updatedAt=DateTime.UtcNow.ToString("o")}); }
                    Thread.Sleep(3000);
                }
            } finally { Stop(ref child); mutex.ReleaseMutex(); }
        }
    }
    static void Worker(int parent,string device,bool observe) {
        using(var owner=Process.GetProcessById(parent)) {
            int session=Process.GetCurrentProcess().SessionId; int repairs=0; string previousPhysical="";
            while(!owner.HasExited && ConsoleDisplayNative.WTSGetActiveConsoleSessionId()==(uint)session) {
                try {
                    ConsoleDisplayNative.Mode[] modes; var paths=ConsoleDisplayNative.Query(out modes);
                    var adapters=paths.Select(ConsoleDisplayNative.Adapter).ToArray();
                    var physical=new HashSet<string>(paths.Where((p,i)=>p.target.available!=0 && ConsoleDisplayPolicy.Physical(adapters[i],device)).Select(ConsoleDisplayPolicy.Target));
                    string signature=string.Join(";",physical.OrderBy(t=>t));
                    bool reconnected=physical.Count!=0 && signature!=previousPhysical;
                    if(!observe) ConsoleDisplayNative.KeepDisplayOn(physical.Count!=0);
                    var desired=ConsoleDisplayPolicy.Repair(paths,physical);
                    var desiredModes=(ConsoleDisplayNative.Mode[])modes.Clone();
                    bool primaryChanged=ConsoleDisplayPolicy.PhysicalPrimary(desired,desiredModes,physical);
                    int before=paths.Count(p=>(p.flags&1)!=0 && p.target.available!=0);
                    if(!observe && (desired.Length>before || primaryChanged || reconnected)) {
                        // Save evidence before any mode change; status below always comes from a fresh query.
                        Status("before-repair",Describe(paths,modes,device,session,repairs,observe));
                        // Re-issue mode setting on startup/hotplug even if Windows calls a stalled HDMI path active.
                        // No adapter is disabled and every existing virtual path/mode is included.
                        ConsoleDisplayNative.Apply(desired,desiredModes,reconnected); repairs++;
                        paths=ConsoleDisplayNative.Query(out modes);
                    }
                    previousPhysical=signature;
                    Status("display-status",Describe(paths,modes,device,session,repairs,observe));
                } catch(Exception error) { Status("display-status",new{ready=false,session=session,error=error.ToString(),repairs=repairs,updatedAt=DateTime.UtcNow.ToString("o")}); }
                Thread.Sleep(3000);
            }
        }
    }
    static object Describe(ConsoleDisplayNative.DisplayPath[] paths,ConsoleDisplayNative.Mode[] modes,string device,int session,int repairs,bool observe) {
        var targets=paths.Where(p=>p.target.available!=0).GroupBy(ConsoleDisplayPolicy.Target).Select(g=>g.OrderByDescending(p=>p.flags&1).First()).Select(p=>new {
            target=ConsoleDisplayPolicy.Target(p),name=ConsoleDisplayNative.Name(p),adapter=ConsoleDisplayNative.Adapter(p),active=(p.flags&1)!=0,
            physical=ConsoleDisplayPolicy.Physical(ConsoleDisplayNative.Adapter(p),device),virtualDisplay=ConsoleDisplayPolicy.Virtual(ConsoleDisplayNative.Adapter(p),device),
            width=p.source.mode<modes.Length?modes[p.source.mode].width:0,height=p.source.mode<modes.Length?modes[p.source.mode].height:0,
            x=p.source.mode<modes.Length?modes[p.source.mode].x:0,y=p.source.mode<modes.Length?modes[p.source.mode].y:0,
            primary=(p.flags&1)!=0 && p.source.mode<modes.Length && modes[p.source.mode].x==0 && modes[p.source.mode].y==0
        }).ToArray();
        return new{ready=targets.Any(t=>t.active) && targets.Where(t=>t.physical).All(t=>t.active),session=session,targets=targets,repairs=repairs,observe=observe,displayPowerRequired=!observe && targets.Any(t=>t.physical),updatedAt=DateTime.UtcNow.ToString("o")};
    }
}
