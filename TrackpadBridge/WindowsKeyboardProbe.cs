using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// A temporary integration probe. Generated Delete events are consumed here,
// so the foreground application never receives a destructive test action.
static class WindowsKeyboardProbe {
 [StructLayout(LayoutKind.Sequential)] struct Key {public uint code,scan,flags,time;public UIntPtr extra;}
 delegate IntPtr Hook(int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int type,Hook callback,IntPtr module,uint thread);
 [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
 [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
 [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll")] static extern uint SendInput(uint count,RoutedKeyboard.Input[] input,int size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string module);
 static IntPtr handle;static Hook callback;static bool testing,deleteHadCtrl,deleteHadWin,restored=true;static int deletes;
 static IntPtr Observe(int code,IntPtr message,IntPtr data) {
  if(code>=0 && testing) {
   var key=(Key)Marshal.PtrToStructure(data,typeof(Key));
   if(key.code==0x2E && key.extra.ToUInt64()==RoutedKeyboard.OwnTag) {
    if((key.flags&0x80)==0){deletes++;deleteHadCtrl|=(GetAsyncKeyState(0x11)&0x8000)!=0;deleteHadWin|=(GetAsyncKeyState(0x5B)&0x8000)!=0 || (GetAsyncKeyState(0x5C)&0x8000)!=0;}
    return new IntPtr(1);
   }
   if((key.code==8 || key.code==0x58) && (key.flags&0x10)!=0 && key.extra==UIntPtr.Zero) {
    CallNextHookEx(handle,code,message,data);return new IntPtr(1);
   }
  }
  return CallNextHookEx(handle,code,message,data);
 }
 static RoutedKeyboard.Input Press(ushort key,bool up) {
  return new RoutedKeyboard.Input{type=1,keyboard=new RoutedKeyboard.Keyboard{key=key,flags=(up?2u:0u)|((key==0x5B || key==0x5C)?1u:0u)}};
 }
 [STAThread] static int Main(string[] args) {
  string result=args.Length==1?args[0]:Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"DJF-Windows","keyboard-native-delete-check-20261023.json");
  foreach(int key in new[]{0x10,0x11,0x12,0x5B,0x5C})if((GetAsyncKeyState(key)&0x8000)!=0) {
   File.WriteAllText(result,"{\"skipped\":\"modifier currently held\"}");return 2;
  }
  callback=Observe;handle=SetWindowsHookEx(13,callback,GetModuleHandle(null),0);
  if(handle==IntPtr.Zero)return 2;
  var native=new RoutedKeyboard();native.SetEnabled(true);var timer=new Timer{Interval=150};int phase=0;bool released=false;
  timer.Tick+=(s,e)=>{
   if(phase==0){testing=true;var input=new[]{Press(0xA2,false),Press(8,false)};SendInput(2,input,40);}
   else if(phase==1){restored&=(GetAsyncKeyState(0x11)&0x8000)!=0;var input=new[]{Press(8,true),Press(0xA2,true)};SendInput(2,input,40);}
   else if(phase==2){var input=new[]{Press(0xA2,false),Press(0x58,false)};SendInput(2,input,40);}
   else if(phase==3){restored&=(GetAsyncKeyState(0x11)&0x8000)!=0;var input=new[]{Press(0x58,true),Press(0xA2,true)};SendInput(2,input,40);}
   else if(phase==4){native.Delete();}
   else if(phase==5){SendInput(1,new[]{Press(0xA2,false)},40);}
   else if(phase==6){native.Delete();}
   else if(phase==7){restored&=(GetAsyncKeyState(0x11)&0x8000)!=0;SendInput(1,new[]{Press(0xA2,true)},40);}
   else if(phase==8){SendInput(1,new[]{Press(0x5B,false)},40);}
   else if(phase==9){native.Delete();}
   else if(phase==10){restored&=(GetAsyncKeyState(0x5B)&0x8000)!=0;var input=RoutedKeyboard.ScreenshotReleaseInputs(0x5B);SendInput((uint)input.Length,input,40);}
   else if(phase==11){SendInput(1,new[]{Press(0x5C,false)},40);}
   else if(phase==12){native.Delete();}
   else if(phase==13){restored&=(GetAsyncKeyState(0x5C)&0x8000)!=0;var input=RoutedKeyboard.ScreenshotReleaseInputs(0x5C);SendInput((uint)input.Length,input,40);}
   else if(phase==14){SendInput(2,new[]{Press(0xA2,false),Press(0x5B,false)},40);}
   else if(phase==15){native.Delete();}
   else if(phase==16){restored&=(GetAsyncKeyState(0x11)&0x8000)!=0 && (GetAsyncKeyState(0x5B)&0x8000)!=0;SendInput(1,new[]{Press(0xA2,true)},40);var input=RoutedKeyboard.ScreenshotReleaseInputs(0x5B);SendInput((uint)input.Length,input,40);}
   else {
    released=(GetAsyncKeyState(0x11)&0x8000)==0 && (GetAsyncKeyState(0x5B)&0x8000)==0 && (GetAsyncKeyState(0x5C)&0x8000)==0;
    timer.Stop();File.WriteAllText(result,new JavaScriptSerializer().Serialize(new{pass=deletes==7 && !deleteHadCtrl && !deleteHadWin && released && restored,deleteEvents=deletes,deleteHadCtrl=deleteHadCtrl,deleteHadWin=deleteHadWin,modifiersReleased=released,modifiersRestored=restored}));Application.ExitThread();
   }
   phase++;
  };
  try{timer.Start();Application.Run();}finally{UnhookWindowsHookEx(handle);timer.Dispose();native.Dispose();}
  return deletes==7 && !deleteHadCtrl && !deleteHadWin && released && restored?0:1;
 }
}
