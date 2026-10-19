using System;
using System.Collections.Generic;

sealed class DeleteShortcut {
 readonly HashSet<ushort> routedControls=new HashSet<ushort>();
 readonly HashSet<ushort> physicalControls=new HashSet<ushort>();
 bool swallowed;
 public bool Handle(uint key,uint flags,ulong extra,bool enabled,bool otherModifier,out ushort[] controls) {
  controls=null;bool injected=(flags&0x10)!=0,up=(flags&0x80)!=0;
  ushort ctrl=0;
  if(key==0x11)ctrl=(ushort)((flags&1)!=0?0xA3:0xA2);
  if(key==0xA2 || key==0xA3)ctrl=(ushort)key;
  if(ctrl!=0) {
   if(!injected){if(up)physicalControls.Remove(ctrl);else physicalControls.Add(ctrl);}
   if(!up && injected && extra==0 && enabled)routedControls.Add(ctrl);
   else routedControls.Remove(ctrl);
   return false;
  }
  if((key!=8 && key!=0x58) || !injected || extra!=0)return false;
  if(up){bool consume=swallowed;swallowed=false;return consume;}
  if(!enabled || otherModifier || physicalControls.Count!=0 || routedControls.Count==0)return false;
  controls=new ushort[routedControls.Count];routedControls.CopyTo(controls);swallowed=true;return true;
 }
 public void Reset(){routedControls.Clear();physicalControls.Clear();swallowed=false;}
}
