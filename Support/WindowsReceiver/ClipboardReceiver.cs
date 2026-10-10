using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public sealed class ClipboardPacket { public string id,text,html,rtf,png; }
public sealed class ClipboardMessage { public string hello; public ClipboardPacket clipboard; }

public static class SharedClipboard {
    public const string Marker="LocalInputRouter.ClipboardID";
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr window);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr memory);

    static byte[] Raw(string name) {
        if(!OpenClipboard(IntPtr.Zero))throw new System.Runtime.InteropServices.ExternalException("Clipboard busy");
        try {
            var handle=GetClipboardData(RegisterClipboardFormat(name));if(handle==IntPtr.Zero)return null;
            var ptr=GlobalLock(handle);if(ptr==IntPtr.Zero)return null;
            try {var bytes=new byte[checked((int)GlobalSize(handle).ToUInt64())];Marshal.Copy(ptr,bytes,0,bytes.Length);return bytes;}
            finally {GlobalUnlock(handle);}
        }finally {CloseClipboard();}
    }
    static byte[] TrimNull(byte[] bytes) {
        if(bytes==null)return null;int length=bytes.Length;while(length>0&&bytes[length-1]==0)length--;
        if(length!=bytes.Length)Array.Resize(ref bytes,length);return bytes;
    }
    public static ClipboardPacket Capture() {
        var packet=new ClipboardPacket{id=Guid.NewGuid().ToString()};
        if(Clipboard.ContainsText(TextDataFormat.UnicodeText))packet.text=Clipboard.GetText(TextDataFormat.UnicodeText);
        var html=Raw(DataFormats.Html);
        if(html!=null) {
            string source=Encoding.UTF8.GetString(html);
            var start=Regex.Match(source,@"StartHTML:(\d+)");var end=Regex.Match(source,@"EndHTML:(\d+)");
            if(start.Success&&end.Success) {
                int a=int.Parse(start.Groups[1].Value),b=int.Parse(end.Groups[1].Value);
                if(a>=0&&b>a&&b<=html.Length)packet.html=Encoding.UTF8.GetString(html,a,b-a);
            }
        }
        var rtf=TrimNull(Raw(DataFormats.Rtf));if(rtf!=null)packet.rtf=Convert.ToBase64String(rtf);
        var png=Raw("PNG");
        if(png!=null&&png.Length>8&&png[0]==137&&png[1]==80&&png[2]==78&&png[3]==71)packet.png=Convert.ToBase64String(png);
        else if(Clipboard.ContainsImage())using(var image=Clipboard.GetImage())using(var stream=new MemoryStream()) {
            image.Save(stream,ImageFormat.Png);packet.png=Convert.ToBase64String(stream.ToArray());
        }
        return packet;
    }
    public static string HTML(string value) {
        string prefix="<html><body><!--StartFragment-->",suffix="<!--EndFragment--></body></html>";
        string content=prefix+value+suffix;
        const string template="Version:1.0\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        int head=Encoding.UTF8.GetByteCount(string.Format(template,0,0,0,0));
        return string.Format(template,head,head+Encoding.UTF8.GetByteCount(content),head+Encoding.UTF8.GetByteCount(prefix),head+Encoding.UTF8.GetByteCount(prefix+value))+content;
    }
    public static void Apply(ClipboardPacket packet) {
        var data=new DataObject();var streams=new System.Collections.Generic.List<MemoryStream>();Bitmap image=null;
        try {
            if(packet.text!=null)data.SetData(DataFormats.UnicodeText,packet.text);
            if(packet.html!=null) {var s=new MemoryStream(Encoding.UTF8.GetBytes(HTML(packet.html)+"\0"));streams.Add(s);data.SetData(DataFormats.Html,s);}
            if(packet.rtf!=null) {var bytes=Convert.FromBase64String(packet.rtf);Array.Resize(ref bytes,bytes.Length+1);var s=new MemoryStream(bytes);streams.Add(s);data.SetData(DataFormats.Rtf,s);}
            if(packet.png!=null)using(var stream=new MemoryStream(Convert.FromBase64String(packet.png))) {
                using(var decoded=Image.FromStream(stream))image=new Bitmap(decoded);data.SetData(DataFormats.Bitmap,image);
                var png=new MemoryStream(Convert.FromBase64String(packet.png));streams.Add(png);data.SetData("PNG",png);
            }
            data.SetData(Marker,packet.id??Guid.NewGuid().ToString());
            // Replacing the full data object clears every previous Windows format.
            Clipboard.SetDataObject(data,true,5,80);
        }finally {if(image!=null)image.Dispose();foreach(var s in streams)s.Dispose();}
    }
}

sealed class ClipboardPump:Form {
    protected override bool ShowWithoutActivation { get {return true;} }
    sealed class Session {
        public TcpClient Client;public StreamWriter Writer;readonly object gate=new object();
        public void Send(object value) {lock(gate){Writer.WriteLine(new JavaScriptSerializer{MaxJsonLength=64*1024*1024}.Serialize(value));}}
    }
    readonly string token;
    readonly TcpListener listener=new TcpListener(IPAddress.Loopback,24904);
    readonly System.Windows.Forms.Timer poll=new System.Windows.Forms.Timer{Interval=50};
    Session active;uint sequence;string appliedID="";ClipboardPacket lastPacket;
    public ClipboardPump(string secret) {
        token=secret;ShowInTaskbar=false;FormBorderStyle=FormBorderStyle.None;Opacity=0;
        Shown+=delegate{Hide();listener.Start();Task.Run((Action)Accept);poll.Tick+=delegate{Changed();};poll.Start();};
    }
    void Accept() {while(true){var client=listener.AcceptTcpClient();Task.Run(()=>HandleClient(client));}}
    void HandleClient(TcpClient client) {
        var session=new Session{Client=client};
        using(client)using(var reader=new StreamReader(client.GetStream(),Encoding.UTF8,false,65536,true))
        using(var writer=new StreamWriter(client.GetStream(),new UTF8Encoding(false),65536,true){AutoFlush=true}) {
            session.Writer=writer;client.NoDelay=true;var json=new JavaScriptSerializer{MaxJsonLength=64*1024*1024};
            try {
                string line=reader.ReadLine();if(line==null)return;
                var hello=json.Deserialize<ClipboardMessage>(line);
                if(hello.hello!=token||hello.clipboard==null)return;
                Invoke((Action)(()=>{if(active!=null)active.Client.Close();active=null;Apply(hello.clipboard);active=session;}));
                session.Send(new{ready=true});
                while((line=reader.ReadLine())!=null) {
                    var message=json.Deserialize<ClipboardMessage>(line);
                    if(message.clipboard==null)continue;
                    Invoke((Action)(()=>{if(active==session)Apply(message.clipboard);}));
                    session.Send(new{ack=message.clipboard.id});
                }
            }catch(IOException){}catch(ObjectDisposedException){}catch(Exception){try{session.Send(new{error="Windows 剪贴板暂不可用，请重新连接"});}catch{}}
            finally {BeginInvoke((Action)(()=>{if(active==session){active=null;lastPacket=null;appliedID="";}}));}
        }
    }
    void Apply(ClipboardPacket packet) {SharedClipboard.Apply(packet);lastPacket=packet;appliedID=packet.id;sequence=SharedClipboard.GetClipboardSequenceNumber();}
    void Changed() {
        if(active==null||SharedClipboard.GetClipboardSequenceNumber()==sequence)return;
        try {
            // Deskflow grabs/empties the secondary clipboard as its client starts.
            // Its clipboard transport is disabled; never relay that internal reset.
            if(Clipboard.ContainsData("Deskflow Ownership")&&lastPacket!=null) {Apply(lastPacket);return;}
            var current=Clipboard.GetData(SharedClipboard.Marker) as string;
            if(!string.IsNullOrEmpty(appliedID)&&current==appliedID){sequence=SharedClipboard.GetClipboardSequenceNumber();return;}
            var packet=SharedClipboard.Capture();active.Send(new{clipboard=packet});lastPacket=packet;sequence=SharedClipboard.GetClipboardSequenceNumber();
        }catch(System.Runtime.InteropServices.ExternalException){}catch(IOException){active.Client.Close();active=null;}catch(ObjectDisposedException){active=null;}
    }
}

static class ClipboardReceiver {
    [STAThread] static void Main() {
        bool first;using(var single=new Mutex(true,@"Local\LocalInputRouter.ClipboardReceiver",out first)) {
            if(!first)return;
            string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LocalInputRouter");
            var token=File.ReadAllText(Path.Combine(root,"trackpad.token")).Trim();
            Application.EnableVisualStyles();Application.Run(new ClipboardPump(token));
        }
    }
}
