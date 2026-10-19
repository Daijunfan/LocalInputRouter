// Temporary fixed-byte echo only; no keyboard/mouse or other remote operations.
using System;using System.IO;using System.Net;using System.Net.Sockets;using System.Threading.Tasks;
sealed class BluetoothEndpoint:EndPoint {
 public uint Channel;
 public BluetoothEndpoint(uint channel){Channel=channel;}
 public override AddressFamily AddressFamily{get{return (AddressFamily)32;}}
 public override SocketAddress Serialize(){var a=new SocketAddress(AddressFamily,30);var bytes=BitConverter.GetBytes(Channel);for(int i=0;i<4;i++)a[26+i]=bytes[i];return a;}
 public override EndPoint Create(SocketAddress a){uint channel=0;for(int i=0;i<4;i++)channel|=(uint)a[26+i]<<(i*8);return new BluetoothEndpoint(channel);}
}
static class BluetoothLatencyProbe {
 static void Main(string[] args) {
  Socket listener=null,client=null;
  try {
   int protocol=args.Length>1 && args[1]=="l2cap" ? 256 : 3;
   listener=new Socket((AddressFamily)32,SocketType.Stream,(ProtocolType)protocol);
   if(protocol==3){
    listener.SetSocketOption((SocketOptionLevel)3,unchecked((SocketOptionName)0x80000001),1);
    listener.SetSocketOption((SocketOptionLevel)3,(SocketOptionName)2,1);
   }
   listener.Bind(new BluetoothEndpoint(UInt32.MaxValue));listener.Listen(1);
   var endpoint=(BluetoothEndpoint)listener.LocalEndPoint;
   File.WriteAllText(args[0],"{\"ready\":true,\"channel\":"+endpoint.Channel+"}");
   Task.Delay(120000).ContinueWith(_=>{if(client!=null)client.Close();listener.Close();});
   client=listener.Accept();var buffer=new byte[2048];int count;
   while((count=client.Receive(buffer))>0){int sent=0;while(sent<count)sent+=client.Send(buffer,sent,count-sent,SocketFlags.None);}
  }catch(Exception e){File.WriteAllText(args[0],"{\"ready\":false,\"error\":\""+e.GetType().Name+"\",\"code\":"+(e is SocketException?((SocketException)e).ErrorCode:0)+"}");}
  finally{if(client!=null)client.Close();if(listener!=null)listener.Close();}
 }
}
