using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;

static class ConsoleDisplayChecks {
    static void Check(bool value,string message) { if(!value) throw new Exception(message); }
    static ConsoleDisplayNative.DisplayPath Path(uint adapter,uint source,uint target,bool active) {
        return new ConsoleDisplayNative.DisplayPath {
            source=new ConsoleDisplayNative.Source{adapter=new ConsoleDisplayNative.Luid{low=adapter},id=source,mode=active?3u:uint.MaxValue},
            target=new ConsoleDisplayNative.Target{adapter=new ConsoleDisplayNative.Luid{low=adapter},id=target,mode=active?4u:uint.MaxValue,available=1},flags=active?1u:0u
        };
    }
    static int Main() {
        Check(Marshal.SizeOf(typeof(ConsoleDisplayNative.DisplayPath))==72,"DISPLAYCONFIG_PATH_INFO ABI");
        Check(Marshal.SizeOf(typeof(ConsoleDisplayNative.Mode))==64,"DISPLAYCONFIG_MODE_INFO ABI");
        string device=@"ROOT\DISPLAY\0000";
        Check(ConsoleDisplayPolicy.Virtual(@"\\?\ROOT#DISPLAY#0000#{guid}",device),"Recognize the pinned virtual adapter");
        Check(!ConsoleDisplayPolicy.Physical(@"\\?\ROOT#DISPLAY#0000#{guid}",device),"Virtual is not physical even when EDID is present");
        Check(!ConsoleDisplayPolicy.Physical(@"\\?\SWD#RemoteDisplayEnum#RDPIDD",device),"RDP never counts as physical");
        Check(ConsoleDisplayPolicy.Physical(@"\\?\PCI#VEN_10DE#GPU",device),"NVIDIA HDMI is physical");
        var headless=Path(1,0,0,true); var hdmi=Path(2,0,4352,false);
        var physical=new HashSet<string>{ConsoleDisplayPolicy.Target(hdmi)};
        var result=ConsoleDisplayPolicy.Repair(new[]{headless,hdmi},physical);
        Check(result.Length==2,"Enable HDMI alongside the existing virtual screen");
        Check(result[0].source.mode==3 && result[0].target.mode==4,"Retain existing virtual mode indexes");
        Check(result[1].source.mode==uint.MaxValue && result[1].target.mode==uint.MaxValue,"Let Windows select the added monitor mode");
        Check(result[1].target.numerator==0 && result[1].target.denominator==0 && result[1].target.scan==0,"Valid automatic refresh selection");
        // The same target can have several possible paths; do not clone or activate it twice.
        var alternate=Path(2,1,4352,false);
        result=ConsoleDisplayPolicy.Repair(new[]{headless,hdmi,alternate},physical);
        Check(result.Length==2,"One path per target");
        var first=Path(2,0,100,true); var second=Path(2,0,200,false); var unused=Path(2,1,200,false);
        physical=new HashSet<string>{ConsoleDisplayPolicy.Target(first),ConsoleDisplayPolicy.Target(second)};
        result=ConsoleDisplayPolicy.Repair(new[]{first,second,unused},physical);
        Check(result.Length==2 && result[1].source.id==1,"Choose an unused source to preserve an existing monitor");
        result=ConsoleDisplayPolicy.Repair(new[]{headless},new HashSet<string>());
        Check(result.Length==1 && result[0].source.mode==3,"No physical monitor leaves the headless desktop unchanged");
        headless.flags=0;
        result=ConsoleDisplayPolicy.Repair(new[]{headless},new HashSet<string>());
        Check(result.Length==1 && (result[0].flags&1)!=0,"Restore a display if no output is active");
        hdmi=Path(2,0,4352,true);
        result=ConsoleDisplayPolicy.Repair(new[]{headless,hdmi},new HashSet<string>{ConsoleDisplayPolicy.Target(hdmi)});
        Check(result.Length==1 && result[0].source.adapter.low==2,"Do not change an already healthy physical desktop");
        headless=Path(1,0,0,true); headless.source.mode=0; hdmi.source.mode=1;
        var modes=new[]{new ConsoleDisplayNative.Mode{type=1,x=0,y=0,width=1920,height=1080},new ConsoleDisplayNative.Mode{type=1,x=1920,y=100,width=3840,height=2160}};
        physical=new HashSet<string>{ConsoleDisplayPolicy.Target(hdmi)};
        Check(ConsoleDisplayPolicy.PhysicalPrimary(new[]{headless,hdmi},modes,physical),"Physical monitor becomes primary for local login");
        Check(modes[1].x==0 && modes[1].y==0 && modes[0].x==-1920 && modes[0].y==-100,"Preserve the relative screen layout");
        Check(modes[0].width==1920 && modes[1].width==3840,"Preserve virtual and physical resolutions");
        Check(!ConsoleDisplayPolicy.PhysicalPrimary(new[]{headless,hdmi},modes,physical),"A healthy primary is unchanged on subsequent checks");
        Console.WriteLine("Console display ABI and topology policy checks passed."); return 0;
    }
}
