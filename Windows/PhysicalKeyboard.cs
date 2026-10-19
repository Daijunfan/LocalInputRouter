// Host-attached keyboards follow the authenticated djf RDP desktop. With no
// active RDP session there is no hook: Windows handles the local keyboard itself.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

struct PhysicalKey {
    public ushort key, scan;
    public uint flags; // KEYEVENTF_EXTENDEDKEY / KEYEVENTF_KEYUP
    public bool Up { get { return (flags & 2) != 0; } }
    public uint Identity { get { return ((uint)key << 17) | ((uint)scan << 1) | (flags & 1); } }
    public static bool IsPhysical(uint hookFlags) { return (hookFlags & 0x10) == 0; }
    public static PhysicalKey FromHook(uint key, uint scan, uint flags) {
        return new PhysicalKey { key=(ushort)key, scan=(ushort)(key == 0x13 ? 0 : scan), flags=(flags & 1) | ((flags & 0x80) != 0 ? 2u : 0u) };
    }
    public PhysicalKeyboardNative.Input Input {
        get { return new PhysicalKeyboardNative.Input { type=1, keyboard=new PhysicalKeyboardNative.Keyboard {
            key=scan == 0 ? key : (ushort)0, scan=scan, flags=flags | (scan == 0 ? 0u : 8u), extra=new UIntPtr(0x444A4650) } }; }
    }
}

static class PhysicalKeyboardNative {
    [StructLayout(LayoutKind.Sequential)] public struct HookKey { public uint key, scan, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct Keyboard { public ushort key,scan; public uint flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit,Size=40)] public struct Input { [FieldOffset(0)] public uint type; [FieldOffset(8)] public Keyboard keyboard; }
    [StructLayout(LayoutKind.Sequential)] struct Session { public int id; public IntPtr station; public int state; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title; public int x,y,width,height,xChars,yChars,fill,flags;
        public short show,reservedSize; public IntPtr reservedData,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential,Pack=1)] struct Privilege { public int count; public long luid; public int attributes; }
    public delegate IntPtr Hook(int code,IntPtr message,IntPtr data);
    [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SetWindowsHookEx(int type,Hook callback,IntPtr module,uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
    [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] input,int size);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle,int field,StringBuilder value,int size,out int needed);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string module);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll",EntryPoint="WTSEnumerateSessionsW",SetLastError=true)] static extern bool Sessions(IntPtr server,int reserved,int version,out IntPtr buffer,out int count);
    [DllImport("wtsapi32.dll",EntryPoint="WTSQuerySessionInformationW",SetLastError=true)] static extern bool Query(IntPtr server,int session,int field,out IntPtr buffer,out int bytes);
    [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSQueryUserToken(uint session,out IntPtr token);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr token,uint access,IntPtr attributes,int level,int type,out IntPtr duplicate);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetTokenInformation(IntPtr token,int field,ref int value,int size);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out long luid);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref Privilege privileges,int size,IntPtr previous,IntPtr needed);
    [DllImport("advapi32.dll",EntryPoint="CreateProcessAsUserW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateUserProcess(IntPtr token,string application,StringBuilder command,IntPtr processAttrs,IntPtr threadAttrs,bool inherit,uint flags,IntPtr env,string directory,ref Startup startup,out ProcessInfo process);
    public static void Check(bool success) { if(!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static int Field(int session,int field,bool small) {
        IntPtr value; int bytes; if(!Query(IntPtr.Zero,session,field,out value,out bytes)) return -1;
        try { return small ? Marshal.ReadInt16(value) : Marshal.ReadInt32(value); } finally { WTSFreeMemory(value); }
    }
    public static bool ActiveRDP(int session) { return session > 0 && (uint)session != WTSGetActiveConsoleSessionId() && Field(session,8,false)==0 && Field(session,16,true)==2; }
    public static int Target(string sid) {
        IntPtr buffer; int count; Check(Sessions(IntPtr.Zero,0,1,out buffer,out count));
        try {
            int size=Marshal.SizeOf(typeof(Session));
            for(int i=0;i<count;i++) {
                var session=(Session)Marshal.PtrToStructure(new IntPtr(buffer.ToInt64()+i*size),typeof(Session));
                if(session.state!=0 || !ActiveRDP(session.id)) continue;
                IntPtr token; if(!WTSQueryUserToken((uint)session.id,out token)) continue;
                try { using(var identity=new WindowsIdentity(token)) if(identity.User.Value==sid) return session.id; }
                finally { CloseHandle(token); }
            }
            return -1;
        } finally { WTSFreeMemory(buffer); }
    }
    public static string InputDesktop() {
        IntPtr desktop=OpenInputDesktop(0,false,1); if(desktop==IntPtr.Zero) return "";
        try { var name=new StringBuilder(256); int needed; Check(GetUserObjectInformation(desktop,2,name,name.Capacity*2,out needed)); return name.ToString(); }
        finally { CloseDesktop(desktop); }
    }
    public static Process Start(int session,string desktop,string arguments) {
        IntPtr own,token; Check(OpenProcessToken(Process.GetCurrentProcess().Handle,0x2A,out own));
        try {
            long luid; Check(LookupPrivilegeValue(null,"SeTcbPrivilege",out luid));
            var privilege=new Privilege{count=1,luid=luid,attributes=2}; Check(AdjustTokenPrivileges(own,false,ref privilege,0,IntPtr.Zero,IntPtr.Zero));
            Check(DuplicateTokenEx(own,0x02000000,IntPtr.Zero,2,1,out token));
            try {
                Check(SetTokenInformation(token,12,ref session,4));
                string app=Process.GetCurrentProcess().MainModule.FileName;
                var startup=new Startup{cb=Marshal.SizeOf(typeof(Startup)),desktop="winsta0\\"+desktop,flags=1,show=0}; ProcessInfo process;
                Check(CreateUserProcess(token,app,new StringBuilder("\""+app+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,Path.GetDirectoryName(app),ref startup,out process));
                try { return Process.GetProcessById(process.pid); } finally { CloseHandle(process.thread); CloseHandle(process.process); }
            } finally { CloseHandle(token); }
        } finally { CloseHandle(own); }
    }
    public static void Send(PhysicalKey key) { Check(SendInput(1,new[]{key.Input},40)==1); }
}

static class PhysicalKeyboard {
    static readonly string Root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"DJF-Windows","PhysicalKeyboard");
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static void Status(string name,object value) { File.WriteAllText(Path.Combine(Root,name+".json"),Json.Serialize(value)); }
    static string Role="broker";
    [STAThread] static int Main(string[] args) {
        try {
            if(Environment.MachineName!="DJF" || !WindowsIdentity.GetCurrent().IsSystem) throw new InvalidOperationException("Only the DJF-Windows SYSTEM task may run this component");
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
            if(args.Length==2 && args[0]=="--broker") { Broker(args[1]); return 0; }
            if(args.Length==5 && (args[0]=="--capture" || args[0]=="--receive")) {
                Role=args[0].Substring(2); int target=int.Parse(args[2]); int parent=int.Parse(args[3]); int console=int.Parse(args[4]);
                if(Role=="capture") Capture(args[1],target,parent,console); else Receive(args[1],target,parent);
                return 0;
            }
            return 2;
        } catch(Exception error) { Status(Role,new{ready=false,error=error.Message,pid=Process.GetCurrentProcess().Id}); return 1; }
    }
    static void Stop(ref Process source,ref Process sink) {
        if(source!=null) { if(!source.HasExited) { source.Kill(); source.WaitForExit(2000); } source.Dispose(); source=null; }
        // EOF releases the receiver's held keys before it exits.
        if(sink!=null) { if(!sink.HasExited && !sink.WaitForExit(2000)) sink.Kill(); sink.Dispose(); sink=null; }
    }
    static void Broker(string sid) {
        new SecurityIdentifier(sid); // Installer pins the existing SSH user's identity.
        using(var mutex=new Mutex(false,@"Global\DJF.PhysicalKeyboard")) {
            if(!mutex.WaitOne(0)) return;
            Process source=null,sink=null; int target=-1,console=-1;
            try {
                while(true) {
                    try {
                        int next=PhysicalKeyboardNative.Target(sid),local=(int)PhysicalKeyboardNative.WTSGetActiveConsoleSessionId();
                        if(next!=target || local!=console || (source!=null && source.HasExited) || (sink!=null && sink.HasExited)) { Stop(ref source,ref sink); target=next; console=local; }
                        if(target>=0 && console>0 && source==null) {
                            string pipe="DJF.PhysicalKeyboard."+Guid.NewGuid().ToString("N");
                            string parameters=pipe+" "+target+" "+Process.GetCurrentProcess().Id+" "+console;
                            sink=PhysicalKeyboardNative.Start(target,"Default","--receive "+parameters);
                            source=PhysicalKeyboardNative.Start(console,"Winlogon","--capture "+parameters);
                        }
                        Status("broker",new{ready=true,mode=target<0?"console":"rdp",targetSession=target,consoleSession=console,
                            capturePID=source==null?0:source.Id,receiverPID=sink==null?0:sink.Id,pid=Process.GetCurrentProcess().Id});
                    } catch(Exception error) { Stop(ref source,ref sink); Status("broker",new{ready=false,error=error.Message}); }
                    Thread.Sleep(1000);
                }
            } finally { Stop(ref source,ref sink); mutex.ReleaseMutex(); }
        }
    }
    static void Write(BinaryWriter writer,PhysicalKey key) { writer.Write(key.key); writer.Write(key.scan); writer.Write(key.flags); writer.Flush(); }
    static PhysicalKey Read(BinaryReader reader) { return new PhysicalKey{key=reader.ReadUInt16(),scan=reader.ReadUInt16(),flags=reader.ReadUInt32()}; }
    static void Capture(string name,int target,int parent,int console) {
        using(var owner=Process.GetProcessById(parent))
        using(var pipe=new NamedPipeClientStream(".",name,PipeDirection.Out,PipeOptions.None))
        using(var queue=new BlockingCollection<PhysicalKey>(128)) {
            pipe.Connect(3000); bool connected=true; long forwarded=0; var held=new HashSet<uint>();
            var writer=new Thread(delegate() {
                try { using(var stream=new BinaryWriter(pipe,Encoding.UTF8,true)) foreach(var key in queue.GetConsumingEnumerable()) Write(stream,key); }
                catch(IOException) { connected=false; }
                catch(ObjectDisposedException) { connected=false; }
            }) { IsBackground=true }; writer.Start();
            PhysicalKeyboardNative.Hook callback=delegate(int code,IntPtr message,IntPtr data) {
                if(code>=0 && connected) {
                    var raw=(PhysicalKeyboardNative.HookKey)Marshal.PtrToStructure(data,typeof(PhysicalKeyboardNative.HookKey));
                    if(raw.key>0 && raw.key<255 && PhysicalKey.IsPhysical(raw.flags)) {
                        var key=PhysicalKey.FromHook(raw.key,raw.scan,raw.flags);
                        if(!key.Up || held.Contains(key.Identity)) {
                            if(queue.TryAdd(key)) { if(key.Up) held.Remove(key.Identity); else held.Add(key.Identity); Interlocked.Increment(ref forwarded); return new IntPtr(1); }
                            connected=false;
                        }
                    }
                }
                return PhysicalKeyboardNative.CallNextHookEx(IntPtr.Zero,code,message,data);
            };
            IntPtr hook=PhysicalKeyboardNative.SetWindowsHookEx(13,callback,PhysicalKeyboardNative.GetModuleHandle(null),0);
            PhysicalKeyboardNative.Check(hook!=IntPtr.Zero);
            using(var timer=new System.Windows.Forms.Timer{Interval=250}) {
                timer.Tick+=delegate {
                    if(owner.HasExited || !connected || (int)PhysicalKeyboardNative.WTSGetActiveConsoleSessionId()!=console || !PhysicalKeyboardNative.ActiveRDP(target) || !queue.TryAdd(new PhysicalKey())) { Application.ExitThread(); return; }
                    Status("capture",new{ready=true,pid=Process.GetCurrentProcess().Id,session=console,desktop=PhysicalKeyboardNative.InputDesktop(),forwarded=Interlocked.Read(ref forwarded)});
                };
                try { timer.Start(); Application.Run(); }
                finally { PhysicalKeyboardNative.UnhookWindowsHookEx(hook); queue.CompleteAdding(); pipe.Dispose(); GC.KeepAlive(callback); }
            }
        }
    }
    static void Receive(string name,int target,int parent) {
        var security=new PipeSecurity(); security.SetAccessRuleProtection(true,false);
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),PipeAccessRights.FullControl,AccessControlType.Allow));
        var held=new Dictionary<uint,PhysicalKey>(); long injected=0;
        using(var owner=Process.GetProcessById(parent))
        using(var pipe=new NamedPipeServerStream(name,PipeDirection.In,1,PipeTransmissionMode.Byte,PipeOptions.None,4096,4096,security)) {
            pipe.WaitForConnection();
            try {
                using(var reader=new BinaryReader(pipe,Encoding.UTF8,true)) while(true) {
                    var key=Read(reader);
                    if(owner.HasExited || !PhysicalKeyboardNative.ActiveRDP(target) || PhysicalKeyboardNative.InputDesktop()!="Default") break;
                    if(key.key!=0) {
                        PhysicalKeyboardNative.Send(key); injected++;
                        if(key.Up) held.Remove(key.Identity); else held[key.Identity]=key;
                    }
                    Status("receive",new{ready=true,pid=Process.GetCurrentProcess().Id,session=target,injected=injected,held=held.Count});
                }
            } catch(EndOfStreamException) { }
            catch(IOException) { }
            finally { foreach(var heldKey in held.Values) { var up=heldKey; up.flags|=2; PhysicalKeyboardNative.Send(up); } }
        }
    }
}
