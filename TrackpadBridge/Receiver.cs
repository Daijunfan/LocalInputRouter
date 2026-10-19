using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
public sealed class PadMessage { public string type,hello; public int width,height,action; public double x,y; public bool macScroll,begin; public PadContact[] touches; }
static class Receiver {
 static readonly string directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"DJF-Windows");
 static readonly JavaScriptSerializer json=new JavaScriptSerializer {MaxJsonLength=8192};
 static void Status(object value){File.WriteAllText(Path.Combine(directory,"trackpad-status.json"),json.Serialize(value));}
 [STAThread] static int Main(string[] args) {
  if(args.Length==2 && args[0]=="--probe") {
   try {using(var pad=new NativeTouchpad(15600,9600)){pad.Frame(new[]{new PadContact{id=1,x=.5,y=.5}});pad.Reset();}
    File.WriteAllText(args[1],"{\"nativeTouchpad\":true,\"singleContactInjection\":true,\"cancel\":true}");return 0;
   }catch(Exception e){File.WriteAllText(args[1],e.ToString());return 1;}
  }
  bool first;using(var mutex=new Mutex(true,@"Local\DJF.NativeTrackpad",out first)) {
   if(!first)return 0;
   using(var keyboard=new RoutedKeyboard()) {
   try {
    string token=File.ReadAllText(Path.Combine(directory,"trackpad.token")).Trim();
    var listener=new TcpListener(IPAddress.Loopback,24801);listener.Start();
    Status(new{ready=true,connected=false,pid=Process.GetCurrentProcess().Id,version="1.1.1",commandBackspace="Delete",commandX="Delete",threeFingerHorizontal="desktop"});
    while(true)using(var client=listener.AcceptTcpClient()) {
     client.NoDelay=true;client.ReceiveTimeout=2500;
     using(var reader=new StreamReader(client.GetStream(),Encoding.UTF8,false,4096,true))
     using(var writer=new StreamWriter(client.GetStream(),new UTF8Encoding(false),4096,true){AutoFlush=true}) {
      try {
       string line=reader.ReadLine();if(line==null || line.Length>8192)continue;
       var hello=json.Deserialize<PadMessage>(line);
       if(hello.hello!=token)continue;
       using(var pad=new NativeTouchpad(hello.width,hello.height,hello.macScroll)) {
        var scroll=new NativeScroll();
        var desktop=new ThreeFingerDesktop();keyboard.SetEnabled(true);
        writer.WriteLine("{\"ready\":true,\"nativeTouchpad\":true,\"macScroll\":true,\"deleteKey\":true}");
        DateTime nextStatus=DateTime.MinValue;
        while((line=reader.ReadLine())!=null) {
         if(line.Length>8192)throw new InvalidDataException("Frame too long");
         var message=json.Deserialize<PadMessage>(line);
         switch(message.type) {
          case "frame":desktop.Frame(message.touches,pad.Frame);break;
          case "action":pad.Action(message.action);break;
          case "scroll":if(hello.macScroll)scroll.Scroll(message.x,message.y,message.begin);break;
          case "delete":keyboard.Delete();break;
          case "reset":desktop.Reset();pad.Reset();scroll.Reset();break;
          case "ping":writer.WriteLine("{\"pong\":true}");break;
          default:throw new InvalidDataException("Unknown input message");
         }
         if(DateTime.UtcNow>=nextStatus) {
          Status(new{ready=true,connected=true,pid=Process.GetCurrentProcess().Id,version="1.1.1",frames=pad.Frames,maxContacts=pad.MaxContacts,macScroll=hello.macScroll,scrollEvents=scroll.Events,wheelX=scroll.WheelX,wheelY=scroll.WheelY,threeFingerDesktopFrames=desktop.MappedFrames,deleteRemaps=keyboard.Remaps});
          nextStatus=DateTime.UtcNow.AddSeconds(1);
         }
        }
       }
      }catch(Exception e) {
       try{writer.WriteLine(json.Serialize(new{error=e.Message}));}catch(IOException){}
       Status(new{ready=true,connected=false,pid=Process.GetCurrentProcess().Id,error=e.Message});
      }finally{keyboard.SetEnabled(false);}
     }
    }
   }catch(Exception e){Status(new{ready=false,error=e.Message});return 1;}
   }
  }
 }
}
