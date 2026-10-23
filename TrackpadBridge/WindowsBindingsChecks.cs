using System;
using System.Collections.Generic;

static class WindowsBindingsChecks {
 static void Check(bool value,string message){if(!value)throw new Exception(message);}
 static PadContact[] Contacts(int count,double dx,double dy) {
  var result=new PadContact[count];for(int i=0;i<count;i++)result[i]=new PadContact{id=i,x=.3+i*.15+dx,y=.5+dy};return result;
 }
 static int Main() {
  var output=new List<PadContact[]>();var map=new ThreeFingerDesktop();
  map.Frame(Contacts(3,0,0),output.Add);Check(output.Count==1 && output[0].Length==0,"Start must clear prior native contacts");
  map.Frame(Contacts(3,-.03,0),output.Add);
  Check(output.Count==3 && output[1].Length==4 && output[2].Length==4,"Horizontal three fingers must become four");
  Check(output[2][3].id==Int32.MaxValue,"Fourth contact needs a stable distinct id");
  map.Frame(new PadContact[0],output.Add);Check(output[3].Length==0,"Gesture must release all contacts");
  output.Clear();map.Frame(Contacts(3,0,0),output.Add);map.Frame(Contacts(3,0,.04),output.Add);
  Check(output[1].Length==3 && output[2].Length==3,"Vertical three-finger gesture must stay three");
  output.Clear();var four=Contacts(4,0,0);map.Frame(four,output.Add);
  Check(Object.ReferenceEquals(four,output[0]),"Actual four fingers must be passed unchanged");
  map.Reset();output.Clear();map.Frame(Contacts(3,0,0),output.Add);map.Frame(new PadContact[0],output.Add);
  Check(output.Count==2 && output[1].Length==0,"Three-finger tap must not be converted");
  var shortcut=new DeleteShortcut();ushort[] controls;
  shortcut.Handle(0xA2,0x10,0,true,false,out controls);
  Check(shortcut.Handle(8,0x10,0,true,false,out controls) && controls.Length==1 && controls[0]==0xA2,"Routed Command+Backspace must match");
  var input=RoutedKeyboard.DeleteInputs(controls);
  Check(input.Length==4 && input[0].keyboard.key==0xA2 && input[0].keyboard.flags==2,"Ctrl must be released before Delete");
  Check(input[1].keyboard.key==0x2E && input[1].keyboard.flags==1 && input[2].keyboard.flags==3,"Delete down/up must be balanced");
  Check(input[3].keyboard.key==0xA2 && input[3].keyboard.flags==0,"Original Command/Ctrl state must be restored");
  Check(shortcut.Handle(8,0x90,0,true,false,out controls),"Original Backspace up must be consumed");
  shortcut.Reset();shortcut.Handle(0xA2,0,0,true,false,out controls);
  Check(!shortcut.Handle(8,0,0,true,false,out controls),"Physical Windows Ctrl+Backspace must be untouched");
  shortcut.Reset();shortcut.Handle(0xA2,0x10,0,true,false,out controls);
  Check(!shortcut.Handle(8,0x10,0,true,true,out controls),"Other modifiers must not trigger plain Delete");
  Check(!shortcut.Handle(8,0x10,0x444A4656,true,false,out controls),"Voice text injections must be untouched");
  Check(!shortcut.Handle(8,0x10,0,false,false,out controls),"Disconnected receiver must not remap keys");
  shortcut.Reset();shortcut.Handle(0xA2,0x10,0,true,false,out controls);
  Check(!shortcut.Handle(0x58,0x10,0,true,false,out controls),"Routed Command+letter X must remain Cut");
  Check(!shortcut.Handle(0x58,0x90,0,true,false,out controls),"Command+letter X release must remain native");
  shortcut.Reset();shortcut.Handle(0xA2,0,0,true,false,out controls);
  Check(!shortcut.Handle(0x58,0,0,true,false,out controls),"Physical Windows Ctrl+X must remain Cut");
  Check(RoutedKeyboard.DeleteInputs(new ushort[0]).Length==2,"Native RDP Delete must be balanced without Ctrl held");
  foreach(ushort win in new ushort[]{0x5B,0x5C}) {
   var deletion=RoutedKeyboard.DeleteInputs(new[]{win});
   Check(deletion.Length==8 && deletion[2].keyboard.key==win && deletion[2].keyboard.flags==3,"Held RDP Win must be masked and released before Delete");
   Check(deletion[3].keyboard.key==0x2E && deletion[3].keyboard.flags==1 && deletion[4].keyboard.flags==3,"Native RDP Delete must remain balanced");
   Check(deletion[5].keyboard.key==win && deletion[5].keyboard.flags==1,"Held Command/Win must be restored");
   Check(deletion[6].keyboard.key==0xE8 && deletion[6].keyboard.flags==0 && deletion[7].keyboard.flags==2,"Restored Win must not open Start when Command is released");
   var mask=RoutedKeyboard.ScreenshotReleaseInputs(win);
   Check(mask.Length==3 && mask[0].keyboard.key==0xE8 && mask[0].keyboard.flags==0,"Screenshot mask is a non-printing key");
   Check(mask[1].keyboard.key==0xE8 && mask[1].keyboard.flags==2,"Screenshot mask releases its own key");
   Check(mask[2].keyboard.key==win && mask[2].keyboard.flags==3,"Original extended Windows key release is preserved");
   Check(mask[2].keyboard.extra.ToUInt64()==RoutedKeyboard.OwnTag,"Replayed release must not recurse through the hook");
  }
  Console.WriteLine("PASS: three/four-finger distinction; routed and native RDP Delete; physical keys preserved; balanced modifiers");return 0;
 }
}
