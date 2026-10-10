using System;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Automation;

sealed class VoiceDelta {
 public readonly int Remove;public readonly string Append;
 public VoiceDelta(string before,string after) {
  int prefix=0;while(prefix<before.Length && prefix<after.Length && before[prefix]==after[prefix])prefix++;
  if(prefix<before.Length && prefix>0 && Char.IsLowSurrogate(before[prefix]))prefix--;
  Remove=StringInfo.ParseCombiningCharacters(before.Substring(prefix)).Length;
  Append=after.Substring(prefix);
 }
}

sealed class VoiceComposition : IDisposable {
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
 string session="",previous="";IntPtr window;int[] target;
 readonly VoiceInputActivity activity=new VoiceInputActivity();
 static int[] Focus() {
  var focused=AutomationElement.FocusedElement;
  if(focused==null || focused.Current.IsPassword)throw new InvalidOperationException("请先选择 Windows 文本输入框");
  object pattern;
  if(!focused.TryGetCurrentPattern(TextPattern.Pattern,out pattern) && !focused.TryGetCurrentPattern(ValuePattern.Pattern,out pattern))throw new InvalidOperationException("请先选择 Windows 文本输入框");
  return focused.GetRuntimeId();
 }
 public void Begin(string value) {activity.Begin();window=GetForegroundWindow();target=Focus();session=value;previous="";}
 public void Update(string value,string text) {
  if(value!=session)throw new InvalidOperationException("语音输入会话已结束");
  if(activity.Interrupted){End();throw new InvalidOperationException("检测到新的键盘或点击操作，语音已停止");}
  if(GetForegroundWindow()!=window || !Focus().SequenceEqual(target)) {End();throw new InvalidOperationException("Windows 输入目标已改变，语音已停止");}
  if(new[]{0x11,0x12,0x5B,0x5C}.Any(k=>(GetAsyncKeyState(k)&0x8000)!=0))throw new InvalidOperationException("请先松开 Windows 修饰键");
  var delta=new VoiceDelta(previous,text);
  VoiceText.ReplaceTail(delta.Remove,delta.Append);previous=text;
 }
 public void End() {activity.End();session="";previous="";target=null;}
 public void Dispose(){End();activity.Dispose();}
}
