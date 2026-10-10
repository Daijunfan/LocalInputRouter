using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class PadContact { public int id; public double x,y; }
sealed class NativeTouchpad : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Params { public uint type,count,feedback; public IntPtr monitor; public uint width,height,options; }
 [StructLayout(LayoutKind.Sequential)] struct Point { public int x,y; }
 [StructLayout(LayoutKind.Sequential)] struct Pointer {
  public uint type,id,frame,flags; public IntPtr device,target;
  public Point pixel,metric,pixelRaw,metricRaw;
  public uint time,history; public int data; public uint keys; public ulong performance; public uint button;
 }
 [StructLayout(LayoutKind.Explicit,Size=152)] struct Packet { [FieldOffset(0)]public uint type; [FieldOffset(8)]public Pointer pointer; }
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr CreateSyntheticPointerDevice2(ref Params p);
 [DllImport("user32.dll",SetLastError=true)] static extern bool InjectSyntheticPointerInput(IntPtr d,Packet[] p,uint count);
 [DllImport("user32.dll",SetLastError=true)] static extern bool InjectTouchpadAction(IntPtr d,uint action);
 [DllImport("user32.dll")] static extern void DestroySyntheticPointerDevice(IntPtr device);
 readonly IntPtr device; readonly int width,height;
 readonly bool macScroll;
 readonly Dictionary<int,Packet> active=new Dictionary<int,Packet>();
 uint nextId=1;
 public long Frames { get; private set; }
 public int MaxContacts { get; private set; }
 public NativeTouchpad(int width,int height,bool macScroll=false) {
  if(width<1000 || width>40000 || height<1000 || height>40000) throw new ArgumentException("Invalid trackpad dimensions");
  this.width=width;this.height=height;this.macScroll=macScroll;
  var p=new Params{type=5,count=5,feedback=3,width=(uint)width,height=(uint)height,options=3};
  device=CreateSyntheticPointerDevice2(ref p);
  if(device==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
 }
 void Inject(List<Packet> packets) {
  if(packets.Count==0)return;
  var array=packets.ToArray();
  if(!InjectSyntheticPointerInput(device,array,(uint)array.Length)) {
   int error=Marshal.GetLastWin32Error();
   if(error==21) { Thread.Sleep(1); if(InjectSyntheticPointerInput(device,array,(uint)array.Length))return; error=Marshal.GetLastWin32Error(); }
   throw new Win32Exception(error);
  }
 }
 public void Frame(PadContact[] contacts) {
  if(contacts==null || contacts.Length>5) throw new ArgumentException("Invalid contact count");
  // Mac supplies accelerated scroll + momentum separately. Anchor the pair
  // to suppress duplicate Windows panning while preserving pinch/rotation.
  if(macScroll && contacts.Length>0 && (contacts.Length==2)!=(active.Count==2)) Reset();
  double centerX=0,centerY=0;
  if(macScroll && contacts.Length==2) {centerX=(contacts[0].x+contacts[1].x)/2-.5;centerY=(contacts[0].y+contacts[1].y)/2-.5;}
  var next=new Dictionary<int,Packet>();var output=new List<Packet>();
  foreach(var c in contacts) {
   if(c.id<0 || !IsUnit(c.x) || !IsUnit(c.y) || next.ContainsKey(c.id)) throw new ArgumentException("Invalid contact");
   Packet packet;bool previous=active.TryGetValue(c.id,out packet);
   if(!previous) packet=new Packet{type=5,pointer=new Pointer{type=5,id=nextId++}};
   packet.pointer.metric=new Point{x=(int)Math.Round((c.x-centerX)*width),y=(int)Math.Round((1-c.y+centerY)*height)};
   packet.pointer.metricRaw=packet.pointer.metric;
   packet.pointer.flags=(previous?0x20000u:0x10000u)|0x4006u;
   next.Add(c.id,packet);output.Add(packet);
  }
  foreach(var pair in active) if(!next.ContainsKey(pair.Key)){var p=pair.Value;p.pointer.flags=0x40000;output.Add(p);}
  if(output.Count>5) {
   var release=new List<Packet>();foreach(var pair in active) {var p=pair.Value;p.pointer.flags=next.ContainsKey(pair.Key)?0x24006u:0x40000u;release.Add(p);}
   Inject(release);output.RemoveAll(p=>p.pointer.flags==0x40000);
  }
  Inject(output);active.Clear();foreach(var pair in next) active.Add(pair.Key,pair.Value);
  if(active.Count==0)nextId=1;
  Frames++;MaxContacts=Math.Max(MaxContacts,contacts.Length);
 }
 static bool IsUnit(double n){return !Double.IsNaN(n) && n>=0 && n<=1;}
 public void Action(int action) {
  if(action<0 || action>10)throw new ArgumentOutOfRangeException("action");
  if(!InjectTouchpadAction(device,(uint)action))throw new Win32Exception(Marshal.GetLastWin32Error());
 }
 public void Reset() {
  var packets=new List<Packet>();foreach(var item in active.Values){var p=item;p.pointer.flags=0x48000;packets.Add(p);}
  try{Inject(packets);}finally{active.Clear();nextId=1;}
 }
 public void Dispose(){try{Reset();}finally{DestroySyntheticPointerDevice(device);}}
}
