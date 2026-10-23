using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Collections.Generic;
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
public sealed class ClipboardMessage { public string hello,ping; public ClipboardPacket clipboard; }

public static class SharedClipboard {
    public const string Marker="DJF.InputRouter.ClipboardID";
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
    public static bool SameContent(ClipboardPacket a,ClipboardPacket b) {
        if(a==null||b==null||a.text!=b.text||a.html!=b.html||a.rtf!=b.rtf)return false;
        if(a.png==b.png)return true;
        if(a.png==null||b.png==null)return false;
        using(var ai=new Bitmap(new MemoryStream(Convert.FromBase64String(a.png))))
        using(var bi=new Bitmap(new MemoryStream(Convert.FromBase64String(b.png)))) {
            if(ai.Size!=bi.Size)return false;
            using(var x=new Bitmap(ai.Width,ai.Height,PixelFormat.Format32bppArgb))
            using(var y=new Bitmap(bi.Width,bi.Height,PixelFormat.Format32bppArgb)) {
                var area=new Rectangle(0,0,x.Width,x.Height);
                using(var g=Graphics.FromImage(x)){g.PageUnit=GraphicsUnit.Pixel;g.CompositingMode=System.Drawing.Drawing2D.CompositingMode.SourceCopy;g.DrawImage(ai,area,0,0,ai.Width,ai.Height,GraphicsUnit.Pixel);}
                using(var g=Graphics.FromImage(y)){g.PageUnit=GraphicsUnit.Pixel;g.CompositingMode=System.Drawing.Drawing2D.CompositingMode.SourceCopy;g.DrawImage(bi,area,0,0,bi.Width,bi.Height,GraphicsUnit.Pixel);}
                var xd=x.LockBits(area,ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
                var yd=y.LockBits(area,ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
                try {
                    var xr=new byte[x.Width*4];var yr=new byte[xr.Length];
                    for(int row=0;row<x.Height;row++) {
                        Marshal.Copy(IntPtr.Add(xd.Scan0,row*xd.Stride),xr,0,xr.Length);
                        Marshal.Copy(IntPtr.Add(yd.Scan0,row*yd.Stride),yr,0,yr.Length);
                        for(int i=0;i<xr.Length;i++)if(xr[i]!=yr[i])return false;
                    }
                    return true;
                }finally{x.UnlockBits(xd);y.UnlockBits(yd);}
            }
        }
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
    // A blocked SSH stream must never block the STA that watches the Windows clipboard.
    // One draining worker keeps ready/clipboard/ack/pong in their original order.
    internal sealed class Session {
        public TcpClient Client;
        public StreamWriter Writer;
        readonly object gate=new object();
        readonly Queue<object> pending=new Queue<object>();
        bool draining,closed;
        public void Send(object value) {
            lock(gate) {
                if(closed)return;
                pending.Enqueue(value);
                if(draining)return;
                draining=true;
            }
            Task.Run((Action)Drain);
        }
        void Drain() {
            try {
                var json=new JavaScriptSerializer{MaxJsonLength=64*1024*1024};
                while(true) {
                    object message;
                    lock(gate) {
                        if(pending.Count==0){draining=false;return;}
                        message=pending.Dequeue();
                    }
                    string line=json.Serialize(message);
                    if(Encoding.UTF8.GetByteCount(line)>64*1024*1024)
                        throw new InvalidDataException("Clipboard packet exceeds 64 MB");
                    Writer.WriteLine(line);
                }
            } catch(Exception) {
                lock(gate){closed=true;pending.Clear();draining=false;}
                try{Client.Close();}catch(ObjectDisposedException){}
            }
        }
    }
    const int WM_CLIPBOARDUPDATE=0x031D;
    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    readonly string token;
    readonly TcpListener listener=new TcpListener(IPAddress.Loopback,24804);
    readonly System.Windows.Forms.Timer poll=new System.Windows.Forms.Timer{Interval=100};
    Session active;uint sequence;string appliedID="";ClipboardPacket lastPacket;bool applying;
    public ClipboardPump(string secret) {
        token=secret;ShowInTaskbar=false;FormBorderStyle=FormBorderStyle.None;Opacity=0;
        Shown+=delegate{
            Hide();listener.Start();AddClipboardFormatListener(Handle);
            Task.Run((Action)Accept);poll.Tick+=delegate{Changed(false);};poll.Start();
        };
    }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if(m.Msg==WM_CLIPBOARDUPDATE)Changed(true);
    }
    protected override void OnFormClosed(FormClosedEventArgs e) {
        RemoveClipboardFormatListener(Handle);poll.Stop();listener.Stop();
        base.OnFormClosed(e);
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
                Invoke((Action)(()=>{if(active!=null)active.Client.Close();active=null;Apply(hello.clipboard);active=session;session.Send(new{ready=true,ack=hello.clipboard.id});}));
                while((line=reader.ReadLine())!=null) {
                    var message=json.Deserialize<ClipboardMessage>(line);
                    if(message.ping!=null) {
                        // Respond on the STA: a pong proves the clipboard message pump is alive.
                        Invoke((Action)(()=>{if(active==session)session.Send(new{pong=message.ping});}));
                        continue;
                    }
                    if(message.clipboard==null)continue;
                    Invoke((Action)(()=>{if(active==session){Apply(message.clipboard);session.Send(new{ack=message.clipboard.id});}}));
                }
            }catch(IOException){}catch(ObjectDisposedException){}catch(Exception){try{session.Send(new{error="Windows 剪贴板暂不可用，请重新连接"});}catch{}}
            finally {BeginInvoke((Action)(()=>{if(active==session){active=null;lastPacket=null;appliedID="";}}));}
        }
    }
    void Apply(ClipboardPacket packet) {
        if(SharedClipboard.GetClipboardSequenceNumber()==sequence && SharedClipboard.SameContent(packet,lastPacket)) {
            lastPacket=packet;return;
        }
        applying=true;
        try {SharedClipboard.Apply(packet);lastPacket=packet;appliedID=packet.id;sequence=SharedClipboard.GetClipboardSequenceNumber();}
        finally {applying=false;}
    }
    void Changed(bool notification) {
        if(applying||active==null||(!notification&&SharedClipboard.GetClipboardSequenceNumber()==sequence))return;
        try {
            // Deskflow grabs/empties the secondary clipboard as its client starts.
            // Its clipboard transport is disabled; never relay that internal reset.
            if(Clipboard.ContainsData("Deskflow Ownership")&&lastPacket!=null) {Apply(lastPacket);return;}
            var current=Clipboard.GetData(SharedClipboard.Marker) as string;
            if(!string.IsNullOrEmpty(appliedID)&&current==appliedID){sequence=SharedClipboard.GetClipboardSequenceNumber();return;}
            uint capturedSequence=SharedClipboard.GetClipboardSequenceNumber();
            var packet=SharedClipboard.Capture();
            if(SharedClipboard.GetClipboardSequenceNumber()!=capturedSequence)return;
            // RDP may re-render an identical image without our private ownership marker.
            if(!SharedClipboard.SameContent(packet,lastPacket)){active.Send(new{clipboard=packet});lastPacket=packet;}
            sequence=capturedSequence;
        }catch(System.Runtime.InteropServices.ExternalException) {
            // Clipboard ownership may be temporarily locked by the copying application.
            // Keep the previous sequence so the polling fallback retries.
        }catch(IOException) {if(active!=null)active.Client.Close();active=null;}
        catch(ObjectDisposedException) {active=null;}
        catch(Exception) {
            // A malformed foreign clipboard format must not terminate the hidden form.
            // Retry on the next notification / timer tick.
        }
    }
}

static class ClipboardReceiver {
    [STAThread] static void Main() {
        bool first;using(var single=new Mutex(true,@"Local\DJF.ClipboardReceiver",out first)) {
            if(!first)return;
            string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"DJF-Windows");
            var token=File.ReadAllText(Path.Combine(root,"trackpad.token")).Trim();
            Application.EnableVisualStyles();Application.Run(new ClipboardPump(token));
        }
    }
}
