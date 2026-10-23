using System;using System.Drawing;using System.Drawing.Imaging;using System.IO;
static class ClipboardContentChecks {
 static string Png(Bitmap image,float dpi){image.SetResolution(dpi,dpi);using(var s=new MemoryStream()){image.Save(s,ImageFormat.Png);return Convert.ToBase64String(s.ToArray());}}
 static void Check(bool value,string name){if(!value)throw new Exception(name);}
 static int Main(){try{
  using(var image=new Bitmap(5,3,PixelFormat.Format32bppArgb)){
   using(var g=Graphics.FromImage(image)){g.Clear(Color.FromArgb(128,35,90,210));}
   var first=new ClipboardPacket{id="first",png=Png(image,96)};
   var echo=new ClipboardPacket{id="rdp-rendered",png=Png(image,144)};
   Check(first.png!=echo.png,"fixture must use different PNG metadata");
   Check(SharedClipboard.SameContent(first,echo),"RDP re-render of the same pixels must not echo");
   image.SetPixel(2,1,Color.Red);var changed=new ClipboardPacket{png=Png(image,96)};
   Check(!SharedClipboard.SameContent(first,changed),"a real image change must be shared");
   var text=new ClipboardPacket{text="new copy"};
   Check(!SharedClipboard.SameContent(first,text),"text and image must not be conflated");
   Check(!SharedClipboard.SameContent(new ClipboardPacket{text="old"},text),"new text must not be suppressed");
   Check(SharedClipboard.SameContent(new ClipboardPacket{id="one",text="same"},new ClipboardPacket{id="two",text="same"}),"private IDs do not make duplicate content a new copy");
   Check(!SharedClipboard.SameContent(first,new ClipboardPacket{text="stale text",png=first.png}),"mixed text and image remains distinguishable");
   Check(SharedClipboard.SameContent(new ClipboardPacket(),new ClipboardPacket()),"empty clipboard deduplicates");
   Check(!SharedClipboard.SameContent(first,null),"first image is always shared");
  }
  Console.WriteLine("PASS: clipboard image identity, real changes, mixed formats and empty content");return 0;
 }catch(Exception e){Console.WriteLine("FAIL: "+e.Message);return 1;}
 }
}
