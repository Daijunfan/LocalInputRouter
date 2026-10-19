using System;using System.IO;using System.Drawing;using System.Drawing.Imaging;using System.Text;using System.Web.Script.Serialization;using System.Windows.Forms;using System.Security.Cryptography;
class ClipboardProbe {
 [STAThread] static void Main(string[] args) {
  var json=new JavaScriptSerializer{MaxJsonLength=64*1024*1024};string result=args[args.Length-1];
  try {
   if(args[0]=="put") {var packet=json.Deserialize<ClipboardPacket>(File.ReadAllText(args[1],Encoding.UTF8));SharedClipboard.Apply(packet);File.WriteAllText(result,"{\"pass\":true}");return;}
   if(args[0]=="seed") {var data=new DataObject();data.SetText("OLD-WINDOWS-OWNED-CLIPBOARD-FIXTURE");data.SetData("DJF.Clipboard.OldFixture","owned");Clipboard.SetDataObject(data,true);File.WriteAllText(result,"{\"pass\":true}");return;}
   var actual=SharedClipboard.Capture();var expected=json.Deserialize<ClipboardPacket>(File.ReadAllText(args[1],Encoding.UTF8));
   bool text=actual.text==expected.text,html=expected.html==null?actual.html==null:actual.html!=null&&actual.html.Contains("DJF rich clipboard"),rtf=actual.rtf==expected.rtf;bool image=actual.png==null&&expected.png==null;
   if(actual.png!=null&&expected.png!=null) {
    using(var a=new Bitmap(new MemoryStream(Convert.FromBase64String(actual.png))))using(var b=new Bitmap(new MemoryStream(Convert.FromBase64String(expected.png)))) {
     image=a.Size==b.Size;if(image)for(int y=0;y<a.Height;y++)for(int x=0;x<a.Width;x++)if(a.GetPixel(x,y).ToArgb()!=b.GetPixel(x,y).ToArgb())image=false;
    }
   }
   bool oldAbsent=!Clipboard.ContainsData("DJF.Clipboard.OldFixture");bool paste=true;
   if(expected.rtf!=null&&expected.png==null)using(var editor=new RichTextBox()) {var handle=editor.Handle;editor.Paste();paste=editor.Text.Contains("DJF rich clipboard")&&editor.Rtf.Contains("\\b");}
   File.WriteAllText(result,json.Serialize(new{pass=text&&html&&rtf&&image&&oldAbsent&&paste,text=text,html=html,rtf=rtf,image=image,oldAbsent=oldAbsent,paste=paste,actualLength=actual.text==null?-1:actual.text.Length,expectedLength=expected.text==null?-1:expected.text.Length,actualCR=actual.text!=null&&actual.text.Contains("\r"),actualLF=actual.text!=null&&actual.text.Contains("\n"),actualTestPrefix=actual.text!=null&&actual.text.StartsWith("DJF clipboard")}),Encoding.UTF8);
  }catch(Exception e){File.WriteAllText(result,json.Serialize(new{pass=false,error=e.ToString()}),Encoding.UTF8);}
 }
}
