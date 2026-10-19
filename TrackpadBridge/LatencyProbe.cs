using System; using System.Net; using System.Net.Sockets; using System.Threading.Tasks;
static class LatencyProbe {
 static void Main() {
  var listener=new TcpListener(IPAddress.Loopback,24802);listener.Start();
  Task.Delay(120000).ContinueWith(_=>listener.Stop());
  try { while(true) using(var client=listener.AcceptTcpClient()) {
   client.NoDelay=true;client.ReceiveTimeout=15000;
   try {var stream=client.GetStream();var buffer=new byte[2048];int n;
    while((n=stream.Read(buffer,0,buffer.Length))>0)stream.Write(buffer,0,n);
   } catch(System.IO.IOException){}
  }}catch(SocketException){}finally{listener.Stop();}
 }
}
