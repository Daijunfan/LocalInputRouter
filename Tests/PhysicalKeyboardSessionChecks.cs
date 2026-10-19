// Exercises the production SYSTEM/session launcher and hook installation.
// The probe always passes input through and never reads or injects a key.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

static class PhysicalKeyboardSessionChecks {
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr handle,int field,StringBuilder value,int size,out int needed);
    static readonly string Root=@"C:\ProgramData\DJF-Windows\PhysicalKeyboard";
    static int Main(string[] args) {
        try {
            if(args.Length==2 && args[0]=="--probe") {
                var desktop=new StringBuilder(256); int needed;
                PhysicalKeyboardNative.Check(GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()),2,desktop,512,out needed));
                PhysicalKeyboardNative.Hook callback=(code,message,data)=>PhysicalKeyboardNative.CallNextHookEx(IntPtr.Zero,code,message,data);
                IntPtr hook=PhysicalKeyboardNative.SetWindowsHookEx(13,callback,PhysicalKeyboardNative.GetModuleHandle(null),0);
                PhysicalKeyboardNative.Check(hook!=IntPtr.Zero);
                PhysicalKeyboardNative.UnhookWindowsHookEx(hook); GC.KeepAlive(callback);
                File.WriteAllText(Path.Combine(Root,args[1]+"-check.json"),new JavaScriptSerializer().Serialize(new{pass=true,session=Process.GetCurrentProcess().SessionId,desktop=desktop.ToString(),hookInstalled=true}));
                return 0;
            }
            int console=(int)PhysicalKeyboardNative.WTSGetActiveConsoleSessionId();
            foreach(string desktop in new[]{"Default","Winlogon"}) {
                using(var child=PhysicalKeyboardNative.Start(console,desktop,"--probe "+desktop)) {
                    if(!child.WaitForExit(10000) || !File.Exists(Path.Combine(Root,desktop+"-check.json"))) throw new Exception("Desktop probe failed: "+desktop);
                }
            }
            File.WriteAllText(Path.Combine(Root,"session-check.json"),"{\"pass\":true,\"productionLauncher\":true,\"defaultAndWinlogonHooks\":true,\"inputInjected\":false}");
            return 0;
        } catch(Exception error) { File.WriteAllText(Path.Combine(Root,"session-check.json"),new JavaScriptSerializer().Serialize(new{pass=false,error=error.ToString()})); return 1; }
    }
}
