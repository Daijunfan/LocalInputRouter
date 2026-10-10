using System;

// Preserve native Windows gesture handling: only horizontal three-finger
// movement gets a fourth virtual contact. Vertical movement and taps stay three.
sealed class ThreeFingerDesktop {
 enum Direction { None, Pending, Horizontal, Vertical }
 Direction direction;PadContact[] first;
 double originX,originY;
 public long MappedFrames {get;private set;}
 public void Frame(PadContact[] contacts,Action<PadContact[]> inject) {
  if(contacts.Length!=3){Reset();inject(contacts);return;}
  double x=0,y=0;foreach(var c in contacts){x+=c.x/3;y+=c.y/3;}
  if(direction==Direction.None) {
   first=contacts;originX=x;originY=y;direction=Direction.Pending;
   inject(new PadContact[0]);return;
  }
  if(direction==Direction.Pending) {
   double dx=x-originX,dy=y-originY;
   if(Math.Max(Math.Abs(dx),Math.Abs(dy))<.015)return;
   direction=Math.Abs(dx)>Math.Abs(dy)?Direction.Horizontal:Direction.Vertical;
   inject(direction==Direction.Horizontal?Four(first):first);first=null;
  }
  inject(direction==Direction.Horizontal?Four(contacts):contacts);
 }
 PadContact[] Four(PadContact[] contacts) {
  var output=new PadContact[4];Array.Copy(contacts,output,3);double x=0,y=0;
  foreach(var c in contacts){x+=c.x/3;y+=c.y/3;}
  output[3]=new PadContact{id=Int32.MaxValue,x=x,y=y};MappedFrames++;return output;
 }
 public void Reset(){direction=Direction.None;first=null;}
}
