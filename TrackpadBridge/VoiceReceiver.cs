using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public sealed class VoiceMessage {public string hello,type,session,text;}
static class VoiceReceiver {
 [MTAThread] static int Main(string[] args) {
  if(args.Length==1 && args[0]=="--test") {
   var a=new VoiceDelta("今天晴","今天天气晴");var b=new VoiceDelta("😀晴天","😀阴天");
   if(a.Remove!=1 || a.Append!="天气晴" || b.Remove!=2 || b.Append!="阴天")return 1;
   Console.WriteLine("PASS: live append, correction, UTF-16 prefix and owned-tail deletion");return 0;
  }
  string directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"DJF-Windows");
  string token=File.ReadAllText(Path.Combine(directory,"trackpad.token")).Trim();
  var json=new JavaScriptSerializer{MaxJsonLength=65536};bool first;
  using(var mutex=new Mutex(true,@"Local\DJF.VoiceReceiver",out first)) {
   if(!first)return 0;
   var listener=new TcpListener(IPAddress.Loopback,24803);listener.Start();
   File.WriteAllText(Path.Combine(directory,"voice-status.json"),"{\"listening\":true}");
   while(true)using(var client=listener.AcceptTcpClient()) {
    client.NoDelay=true;
    using(var reader=new StreamReader(client.GetStream(),Encoding.UTF8,false,4096,true))
    using(var writer=new StreamWriter(client.GetStream(),new UTF8Encoding(false),4096,true){AutoFlush=true}) {
     using(var composition=new VoiceComposition())
     {
     try {
      string firstLine=reader.ReadLine();if(firstLine==null)continue;
      var hello=json.Deserialize<VoiceMessage>(firstLine);if(hello.hello!=token)continue;
      writer.WriteLine("{\"ready\":true}");string line;
      int receivedUpdates=0,acknowledgedUpdates=0,characters=0;string lastError="";
      File.WriteAllText(Path.Combine(directory,"voice-status.json"),json.Serialize(new{listening=true,connected=true,version="1.0.1",lastMessage="ready",receivedUpdates,acknowledgedUpdates,characters,lastError,updatedAt=DateTime.UtcNow.ToString("o")}));
      while((line=reader.ReadLine())!=null) {
       var message=json.Deserialize<VoiceMessage>(line);
       try {
        switch(message.type) {
         case "begin":lastError="";receivedUpdates=0;acknowledgedUpdates=0;characters=0;composition.Begin(message.session);break;
         case "update":receivedUpdates++;characters=message.text.Length;composition.Update(message.session,message.text);acknowledgedUpdates++;writer.WriteLine(json.Serialize(new{characters}));break;
         case "end":case "cancel":composition.End();break;
         default:throw new InvalidDataException("Unknown voice message");
        }
       }catch(Exception e){lastError=e.Message;composition.End();writer.WriteLine(json.Serialize(new{error=lastError}));}
       File.WriteAllText(Path.Combine(directory,"voice-status.json"),json.Serialize(new{listening=true,connected=true,version="1.0.1",lastMessage=message.type,receivedUpdates,acknowledgedUpdates,characters,lastError,updatedAt=DateTime.UtcNow.ToString("o")}));
      }
     }catch(IOException){}finally{composition.End();}
     }
    }
   }
  }
 }
}
