using System;

static class PhysicalKeyboardChecks {
    static void Check(bool value) { if(!value) throw new Exception("Physical keyboard regression"); }
    static int Main() {
        Check(PhysicalKey.IsPhysical(0) && PhysicalKey.IsPhysical(0x81));
        Check(!PhysicalKey.IsPhysical(0x10) && !PhysicalKey.IsPhysical(0x92));
        var down=PhysicalKey.FromHook(0xA3,0x1D,1);
        var up=PhysicalKey.FromHook(0xA3,0x1D,0x81);
        Check(!down.Up && up.Up && down.Identity==up.Identity);
        Check(down.Input.keyboard.key==0 && down.Input.keyboard.scan==0x1D && down.Input.keyboard.flags==9);
        Check(up.Input.keyboard.flags==11 && up.Input.keyboard.extra.ToUInt64()!=0);
        Check(PhysicalKey.FromHook(0x13,0x45,0).Input.keyboard.key==0x13); // Pause uses its virtual key.
        Check(PhysicalKey.FromHook(0x13,0x45,0).Identity!=PhysicalKey.FromHook(0x52,0x13,0).Identity);
        Check(PhysicalKey.FromHook(0xA2,0x1D,0).Identity!=down.Identity); // Left/right Ctrl remain distinct.
        var aliases=new DeleteShortcut(); ushort[] controls;
        Check(!aliases.Handle(0xA2,0x10,0x444A4650,true,false,out controls));
        Check(!aliases.Handle(0x58,0x10,0x444A4650,true,false,out controls)); // Physical Ctrl+X stays Cut.
        Console.WriteLine("PASS: physical-only capture, scan/extended/up flags, modifier identity, own injection tag and physical Ctrl+X preservation");
        return 0;
    }
}
