using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

// Fine wheel units, not 120-unit notches. Fractional carry keeps slow motion.
sealed class NativeScroll {
 [StructLayout(LayoutKind.Sequential)] struct Mouse { public int x,y; public uint data,flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Sequential)] struct Input { public uint type; public Mouse mouse; }
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
 double remainderX,remainderY;
 public long Events { get; private set; }
 public long WheelX { get; private set; }
 public long WheelY { get; private set; }
 public void Reset() { remainderX=0; remainderY=0; }
 public int[] Convert(double x,double y,bool begin) {
  if(Double.IsNaN(x) || Double.IsInfinity(x) || Double.IsNaN(y) || Double.IsInfinity(y)) throw new ArgumentException("Invalid scroll delta");
  if(begin) Reset();
  // 100 Mac points per wheel notch. Sign matches Mac's natural scrolling.
  double sx=-x*1.2+remainderX,sy=y*1.2+remainderY;
  int dx=(int)Math.Truncate(sx),dy=(int)Math.Truncate(sy);
  remainderX=sx-dx;remainderY=sy-dy;
  return new[]{dx,dy};
 }
 public void Scroll(double x,double y,bool begin) {
  int[] delta=Convert(x,y,begin);
  var inputs=new System.Collections.Generic.List<Input>();
  if(delta[0]!=0)inputs.Add(new Input{mouse=new Mouse{data=unchecked((uint)delta[0]),flags=0x1000,extra=new UIntPtr(0x444A4653)}});
  if(delta[1]!=0)inputs.Add(new Input{mouse=new Mouse{data=unchecked((uint)delta[1]),flags=0x0800,extra=new UIntPtr(0x444A4653)}});
  if(inputs.Count>0 && SendInput((uint)inputs.Count,inputs.ToArray(),Marshal.SizeOf(typeof(Input)))!=inputs.Count)
   throw new Win32Exception(Marshal.GetLastWin32Error());
  Events++;WheelX+=delta[0];WheelY+=delta[1];
 }
}
