using System;
using System.IO;
using System.Runtime.InteropServices;
static class NativeProbe {
 [StructLayout(LayoutKind.Sequential)] struct CreateParams { public uint type,count,feedback; public IntPtr monitor; public uint width,height,options; }
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr CreateSyntheticPointerDevice2(ref CreateParams p);
 [DllImport("user32.dll")] static extern void DestroySyntheticPointerDevice(IntPtr device);
 [STAThread] static void Main(string[] args) {
   var p=new CreateParams {type=5,count=5,feedback=3,width=16000,height=10000,options=3};
   var device=CreateSyntheticPointerDevice2(ref p);
   int error=Marshal.GetLastWin32Error();
   File.WriteAllText(args[0],"{\"created\":"+(device!=IntPtr.Zero?"true":"false")+",\"error\":"+error+",\"paramsSize\":"+Marshal.SizeOf(p)+"}");
   if(device!=IntPtr.Zero) DestroySyntheticPointerDevice(device);
 }
}
