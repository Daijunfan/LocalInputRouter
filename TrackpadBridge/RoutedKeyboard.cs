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
 volatile bool nativeKeyboard;
 int nativeModifiers;
 readonly HashSet<ushort> nativePressed=new HashSet<ushort>();
 static readonly ushort[] modifierKeys={0xA2,0xA3,0x5B,0x5C,0xA0,0xA1,0xA4,0xA5};
 long nativeKeyEvents,nativeModifierEvents;
 public long NativeKeyEvents {get{return Interlocked.Read(ref nativeKeyEvents);}}
 public long NativeModifierEvents {get{return Interlocked.Read(ref nativeModifierEvents);}}
 public long Remaps {get{return Interlocked.Read(ref remaps);}}
 public void SetEnabled(bool value){if(!value){SetNativeKeyboard(false);resetRequested=true;Interlocked.Exchange(ref screenshotMaskUntil,0);}enabled=value;}
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
    if(nativeKeyboard && (key.flags&0x10)==0 && (key.code==0x11 || key.code==0xA2 || key.code==0xA3 || key.code==0x5B || key.code==0x5C)) {
     Interlocked.Increment(ref nativeModifierEvents);return new IntPtr(1);
    }
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
 public void SetNativeKeyboard(bool value) {
  nativeKeyboard=value;
  if(!value) {
   foreach(var key in nativePressed)Send(new[]{NativePress(key,true)});
   nativePressed.Clear();SyncNativeModifiers(0,true);
  }
 }
 public void NativeModifiers(int modifiers) {nativeKeyboard=true;SyncNativeModifiers(modifiers&15,false);}
 void SyncNativeModifiers(int value,bool maskRelease) {
  var input=new List<Input>();
  for(int i=0;i<4;i++)if((nativeModifiers&(1<<i))!=0 && (value&(1<<i))==0) {
   if(maskRelease && i>=2)input.AddRange(ScreenshotReleaseInputs(modifierKeys[i]));else input.Add(Press(modifierKeys[i],true));
  }
  for(int i=0;i<4;i++)if((nativeModifiers&(1<<i))==0 && (value&(1<<i))!=0)input.Add(Press(modifierKeys[i],false));
  if(input.Count>0)Send(input.ToArray());nativeModifiers=value;
 }
 public void NativeKey(ushort key,bool down,int modifiers) {
  if(!nativeKeyboard)return;
  SyncNativeModifiers(modifiers&15,false);
  // Shift/Alt remain native RDP input. Borrow their requested state for this
  // chord event so independent RDP/SSH arrival times cannot change its meaning.
  var input=new List<Input>();var restore=new List<Input>();
  for(int i=4;i<8;i++) {
   bool held=(GetAsyncKeyState(modifierKeys[i])&0x8000)!=0,wanted=(modifiers&(1<<i))!=0;
   if(held!=wanted){input.Add(Press(modifierKeys[i],!wanted));restore.Add(Press(modifierKeys[i],!held));}
  }
  input.Add(NativePress(key,!down));input.AddRange(restore);Send(input.ToArray());
  if(down)nativePressed.Add(key);else nativePressed.Remove(key);
  Interlocked.Increment(ref nativeKeyEvents);
 }
 static Input NativePress(ushort key,bool up) {
  return new Input{type=1,keyboard=new Keyboard{key=(ushort)(key&255),flags=(up?2u:0u)|((key&256)!=0?1u:0u),extra=new UIntPtr(OwnTag)}};
 }
 static void Send(Input[] input) {
  if(SendInput((uint)input.Length,input,Marshal.SizeOf(typeof(Input)))!=input.Length)throw new Win32Exception(Marshal.GetLastWin32Error());
 }
 public void Delete() {
  var controls=new List<ushort>();
  foreach(ushort key in new ushort[]{0xA2,0xA3,0x5B,0x5C})if((GetAsyncKeyState(key)&0x8000)!=0)controls.Add(key);
  if(!SendDelete(controls.ToArray()))throw new Win32Exception(Marshal.GetLastWin32Error());
 }
 bool SendDelete(ushort[] controls) {
  var inputs=DeleteInputs(controls);
  bool success=SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))==inputs.Length;
  if(success)Interlocked.Increment(ref remaps);return success;
 }
 static Input Press(ushort key,bool up) {
  uint flags=(up?2u:0u)|((key==0x2E || key==0xA3 || key==0xA5 || key==0x5B || key==0x5C)?1u:0u);
  return new Input{type=1,keyboard=new Keyboard{key=key,flags=flags,extra=new UIntPtr(OwnTag)}};
 }
 public static Input[] DeleteInputs(ushort[] controls) {
  var result=new List<Input>();
  foreach(var ctrl in controls) {
   if(ctrl==0x5B || ctrl==0x5C)result.AddRange(ScreenshotReleaseInputs(ctrl));
   else result.Add(Press(ctrl,true));
  }
  result.Add(Press(0x2E,false));result.Add(Press(0x2E,true));
  foreach(var ctrl in controls)result.Add(Press(ctrl,false));
  // Restoring a held Mac Command/Win must not turn its eventual release into Start.
  if(Array.Exists(controls,key=>key==0x5B || key==0x5C)){result.Add(Press(0xE8,false));result.Add(Press(0xE8,true));}
  return result.ToArray();
 }
 public static Input[] ScreenshotReleaseInputs(ushort windowsKey) {
  // Unassigned VK_E8 masks an otherwise bare Win release, without typing a character.
  return new[]{Press(0xE8,false),Press(0xE8,true),Press(windowsKey,true)};
 }
 public void Dispose(){enabled=false;PostThreadMessage(threadId,0x12,UIntPtr.Zero,IntPtr.Zero);}
}
