using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// Read-only activity guard: edits stop before another keyboard/click action.
// No key values or mouse positions are stored; every event is passed through.
sealed class VoiceInputActivity : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Key {public uint code,scan,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] struct Point {public int x,y;}
 [StructLayout(LayoutKind.Sequential)] struct Mouse {public Point point;public uint data,flags,time;public UIntPtr extra;}
 delegate IntPtr Hook(int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int type,Hook callback,IntPtr module,uint thread);
 [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
 [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread,uint message,UIntPtr w,IntPtr l);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string module);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 const ulong OwnTag=0x4C495256;
 readonly Thread worker;readonly ManualResetEvent ready=new ManualResetEvent(false);
 Hook keyCallback,mouseCallback;IntPtr keyHook,mouseHook;uint threadId;
 volatile bool active,interrupted;
 public bool Interrupted {get{return interrupted;}}
 public VoiceInputActivity() {
  worker=new Thread(Run){IsBackground=true,Name="DJF voice activity guard"};worker.Start();ready.WaitOne();
  if(keyHook==IntPtr.Zero || mouseHook==IntPtr.Zero){Dispose();throw new InvalidOperationException("无法保护 Windows 语音输入位置");}
 }
 public void Begin(){interrupted=false;active=true;}
 public void End(){active=false;}
 void Run() {
  threadId=GetCurrentThreadId();keyCallback=KeyEvent;mouseCallback=MouseEvent;
  keyHook=SetWindowsHookEx(13,keyCallback,GetModuleHandle(null),0);
  mouseHook=SetWindowsHookEx(14,mouseCallback,GetModuleHandle(null),0);
  ready.Set();
  try{Application.Run();}finally{if(keyHook!=IntPtr.Zero)UnhookWindowsHookEx(keyHook);if(mouseHook!=IntPtr.Zero)UnhookWindowsHookEx(mouseHook);}
 }
 IntPtr KeyEvent(int code,IntPtr message,IntPtr data) {
  long kind=message.ToInt64();
  if(code>=0 && active && (kind==0x100 || kind==0x104)) {
   var key=(Key)Marshal.PtrToStructure(data,typeof(Key));if(key.extra.ToUInt64()!=OwnTag)interrupted=true;
  }
  return CallNextHookEx(keyHook,code,message,data);
 }
 IntPtr MouseEvent(int code,IntPtr message,IntPtr data) {
  long kind=message.ToInt64();
  if(code>=0 && active && (kind==0x201 || kind==0x204 || kind==0x207)) {
   var mouse=(Mouse)Marshal.PtrToStructure(data,typeof(Mouse));if(mouse.extra.ToUInt64()!=OwnTag)interrupted=true;
  }
  return CallNextHookEx(mouseHook,code,message,data);
 }
 public void Dispose(){active=false;PostThreadMessage(threadId,0x12,UIntPtr.Zero,IntPtr.Zero);}
}
