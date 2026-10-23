using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// Runs in the receiver's interactive Windows session. Physical keyboard input
// passes unchanged; voice/text injections have a nonzero own tag and also pass.
sealed class RoutedKeyboard : IDisposable {
 public const ulong OwnTag=0x444A464B;
 [StructLayout(LayoutKind.Sequential)] struct Key {public uint code,scan,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] public struct Keyboard {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit,Size=40)] public struct Input {[FieldOffset(0)]public uint type;[FieldOffset(8)]public Keyboard keyboard;}
 [StructLayout(LayoutKind.Sequential)] struct Message {public IntPtr window;public uint message;public UIntPtr w;public IntPtr l;public uint time;public int x,y;}
 delegate IntPtr Hook(int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int type,Hook callback,IntPtr module,uint thread);
 [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
 [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
 [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread,uint message,UIntPtr w,IntPtr l);
 [DllImport("user32.dll")] static extern bool PeekMessage(out Message message,IntPtr window,uint first,uint last,uint flags);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string module);
 readonly DeleteShortcut shortcut=new DeleteShortcut();
 readonly ManualResetEvent ready=new ManualResetEvent(false);readonly Thread worker;
 Hook callback;IntPtr hook;uint threadId;volatile bool enabled,resetRequested;
 long remaps;
 long screenshotMaskUntil;
 public long Remaps {get{return Interlocked.Read(ref remaps);}}
 public void SetEnabled(bool value){if(!value){resetRequested=true;Interlocked.Exchange(ref screenshotMaskUntil,0);}enabled=value;}
 public void PrepareLocalScreenshot(){Interlocked.Exchange(ref screenshotMaskUntil,DateTime.UtcNow.AddSeconds(10).Ticks);}
 public RoutedKeyboard() {
  worker=new Thread(Run){IsBackground=true,Name="DJF routed keyboard"};worker.Start();ready.WaitOne();
  if(hook==IntPtr.Zero)throw new Win32Exception("Could not install routed keyboard receiver");
 }
 void Run() {
  threadId=GetCurrentThreadId();Message m;PeekMessage(out m,IntPtr.Zero,0,0,0);
  callback=KeyEvent;hook=SetWindowsHookEx(13,callback,GetModuleHandle(null),0);ready.Set();
  if(hook==IntPtr.Zero)return;
  try{Application.Run();}finally{UnhookWindowsHookEx(hook);}
 }
 IntPtr KeyEvent(int code,IntPtr message,IntPtr data) {
  if(code>=0) {
   if(resetRequested){shortcut.Reset();resetRequested=false;}
   var key=(Key)Marshal.PtrToStructure(data,typeof(Key));
   if(key.extra.ToUInt64()!=OwnTag) {
    if(enabled && (key.code==0x5B || key.code==0x5C) && (key.flags&0x80)!=0 && DateTime.UtcNow.Ticks<=Interlocked.Read(ref screenshotMaskUntil)) {
     Interlocked.Exchange(ref screenshotMaskUntil,0);
     var masked=ScreenshotReleaseInputs((ushort)key.code);
     if(SendInput((uint)masked.Length,masked,Marshal.SizeOf(typeof(Input)))==masked.Length)return new IntPtr(1);
    }
    bool other=(GetAsyncKeyState(0x10)&0x8000)!=0 || (GetAsyncKeyState(0x12)&0x8000)!=0 || (GetAsyncKeyState(0x5B)&0x8000)!=0 || (GetAsyncKeyState(0x5C)&0x8000)!=0;
    ushort[] controls;
    if(shortcut.Handle(key.code,key.flags,key.extra.ToUInt64(),enabled,other,out controls)) {
     if(controls!=null) {
      SendDelete(controls);
     }
     return new IntPtr(1);
    }
   }
  }
  return CallNextHookEx(hook,code,message,data);
 }
 public void Delete() {
  var controls=new List<ushort>();
  foreach(ushort key in new ushort[]{0xA2,0xA3})if((GetAsyncKeyState(key)&0x8000)!=0)controls.Add(key);
  if(!SendDelete(controls.ToArray()))throw new Win32Exception(Marshal.GetLastWin32Error());
 }
 bool SendDelete(ushort[] controls) {
  var inputs=DeleteInputs(controls);
  bool success=SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))==inputs.Length;
  if(success)Interlocked.Increment(ref remaps);return success;
 }
 static Input Press(ushort key,bool up) {
  uint flags=(up?2u:0u)|((key==0x2E || key==0xA3 || key==0x5B || key==0x5C)?1u:0u);
  return new Input{type=1,keyboard=new Keyboard{key=key,flags=flags,extra=new UIntPtr(OwnTag)}};
 }
 public static Input[] DeleteInputs(ushort[] controls) {
  var result=new List<Input>();foreach(var ctrl in controls)result.Add(Press(ctrl,true));
  result.Add(Press(0x2E,false));result.Add(Press(0x2E,true));
  foreach(var ctrl in controls)result.Add(Press(ctrl,false));return result.ToArray();
 }
 public static Input[] ScreenshotReleaseInputs(ushort windowsKey) {
  // Unassigned VK_E8 masks an otherwise bare Win release, without typing a character.
  return new[]{Press(0xE8,false),Press(0xE8,true),Press(windowsKey,true)};
 }
 public void Dispose(){enabled=false;PostThreadMessage(threadId,0x12,UIntPtr.Zero,IntPtr.Zero);}
}
