using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

// Integration fixture: modifies only its own temporary text box.
static class VoiceProbe {
 [StructLayout(LayoutKind.Sequential)] struct Key {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit,Size=40)] struct Input {[FieldOffset(0)]public uint type;[FieldOffset(8)]public Key key;}
 [DllImport("user32.dll")] static extern uint SendInput(uint n,Input[] inputs,int size);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [STAThread] static void Main(string[] args) {
  var form=new Form{Text="DJF 实时文字通道测试",Width=460,Height=180,StartPosition=FormStartPosition.CenterScreen,TopMost=true};
  var box=new RichTextBox{Dock=DockStyle.Fill,Text="prefix "};form.Controls.Add(box);
  var timeout=new System.Windows.Forms.Timer{Interval=5000};timeout.Tick+=(s,e)=>form.Close();timeout.Start();
  form.Shown+=(s,e)=> {
   form.Activate();box.Focus();box.SelectionStart=box.TextLength;
   Task.Run(()=> {
    try {
     Thread.Sleep(150);
     if(GetForegroundWindow()!=form.Handle || !(bool)box.Invoke(new Func<bool>(()=>box.Focused)))throw new Exception("Own test field is not focused");
     using(var composer=new VoiceComposition()) {
      composer.Begin("probe");composer.Update("probe","今天晴");Wait(box,"prefix 今天晴");
      composer.Update("probe","今天天气晴");Wait(box,"prefix 今天天气晴");
      var keys=new[]{new Input{type=1,key=new Key{key=0x25,extra=new UIntPtr(0x444A4650)}},new Input{type=1,key=new Key{key=0x25,flags=2,extra=new UIntPtr(0x444A4650)}}};
      SendInput(2,keys,Marshal.SizeOf(typeof(Input)));Thread.Sleep(50);
      bool interrupted=false;try{composer.Update("probe","不应覆盖用户操作");}catch(InvalidOperationException){interrupted=true;}
      if(!interrupted)throw new Exception("Activity guard did not interrupt");
      Wait(box,"prefix 今天天气晴");
     }
     File.WriteAllText(args[0],"{\"liveAppend\":true,\"correction\":true,\"newInputStopsEditing\":true}");
    }catch(Exception ex){File.WriteAllText(args[0],"{\"error\":\""+ex.GetType().Name+"\",\"message\":\""+ex.Message.Replace("\"","'")+"\"}");}
    finally {if(!form.IsDisposed)form.BeginInvoke(new Action(()=>form.Close()));}
   });
  };
  Application.Run(form);timeout.Dispose();
 }
 static void Wait(RichTextBox box,string expected) {
  var deadline=DateTime.UtcNow.AddSeconds(1);
  while(DateTime.UtcNow<deadline) {
   if((string)box.Invoke(new Func<string>(()=>box.Text))==expected)return;
   Thread.Sleep(10);
  }
  throw new Exception("Own text box did not receive expected fixture");
 }
}
