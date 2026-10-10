using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

static class VoiceText {
 [StructLayout(LayoutKind.Sequential)] struct Keyboard {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit,Size=40)] struct Input {[FieldOffset(0)]public uint type;[FieldOffset(8)]public Keyboard keyboard;}
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
 public static void ReplaceTail(int remove,string append) {
  var inputs=new Input[(remove+append.Length)*2];int index=0;
  for(int i=0;i<remove;i++) {
   inputs[index++]=new Input{type=1,keyboard=new Keyboard{key=8,extra=new UIntPtr(0x4C495256)}};
   inputs[index++]=new Input{type=1,keyboard=new Keyboard{key=8,flags=2,extra=new UIntPtr(0x4C495256)}};
  }
  foreach(char c in append) {
   inputs[index++]=new Input{type=1,keyboard=new Keyboard{scan=c,flags=4,extra=new UIntPtr(0x4C495256)}};
   inputs[index++]=new Input{type=1,keyboard=new Keyboard{scan=c,flags=6,extra=new UIntPtr(0x4C495256)}};
  }
  // One native batch prevents other input from interleaving a correction.
  if(inputs.Length>0 && SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))!=inputs.Length)throw new Win32Exception(Marshal.GetLastWin32Error());
 }
}
