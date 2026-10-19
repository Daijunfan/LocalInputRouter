using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Windows.Automation;
using System.Runtime.InteropServices;

// Isolated authenticated endpoint for the real Mac VoiceBridge/VoiceTransport.
static class VoiceRoutingProbe {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [STAThread] static void Main(string[] args) {
        var json = new JavaScriptSerializer();
        var form = new Form { Text = "InputRouter voice routing check", WindowState = FormWindowState.Maximized, TopMost = true };
        var box = new RichTextBox { Dock = DockStyle.Fill, Text = "prefix " };
        form.Controls.Add(box);
        var timeout = new System.Windows.Forms.Timer { Interval = 30000 };
        timeout.Tick += delegate { form.Close(); }; timeout.Start();
        form.Shown += delegate {
            form.Activate(); box.Focus(); box.SelectionStart = box.TextLength;
            new Thread(delegate() {
                var listener = new TcpListener(IPAddress.Loopback, 24813);
                try {
                    listener.Start();
                    using (var client = listener.AcceptTcpClient()) {
                        client.ReceiveTimeout = 15000;
                        using (var reader = new StreamReader(client.GetStream(), Encoding.UTF8))
                        using (var writer = new StreamWriter(client.GetStream(), new UTF8Encoding(false)) { AutoFlush = true })
                        using (var composition = new VoiceComposition()) {
                            var hello = json.Deserialize<VoiceMessage>(reader.ReadLine());
                            var token = File.ReadAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DJF-Windows", "trackpad.token")).Trim();
                            if (hello.hello != token) throw new Exception("Authentication failed");
                            writer.WriteLine("{\"ready\":true}");
                            string line; int updates = 0;
                            while ((line = reader.ReadLine()) != null) {
                                var message = json.Deserialize<VoiceMessage>(line);
                                if (message.type == "begin") {
                                    box.Invoke(new Action(delegate {
                                        var foreground = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
                                        var current = GetCurrentThreadId();
                                        bool attached = foreground != current && AttachThreadInput(current, foreground, true);
                                        try { SetForegroundWindow(form.Handle); form.Activate(); box.Focus(); }
                                        finally { if (attached) AttachThreadInput(current, foreground, false); }
                                    }));
                                    Thread.Sleep(150);
                                    var focus = AutomationElement.FocusedElement;
                                    object pattern;
                                    File.WriteAllText(Path.Combine(Path.GetDirectoryName(args[0]), "voice-focus.json"),
                                        json.Serialize(new { ownPid = System.Diagnostics.Process.GetCurrentProcess().Id,
                                            focusedPid = focus == null ? 0 : focus.Current.ProcessId,
                                            focusedClass = focus == null ? "null" : focus.Current.ClassName,
                                            password = focus != null && focus.Current.IsPassword,
                                            textPattern = focus != null && focus.TryGetCurrentPattern(TextPattern.Pattern, out pattern),
                                            valuePattern = focus != null && focus.TryGetCurrentPattern(ValuePattern.Pattern, out pattern),
                                            boxFocused = (bool)box.Invoke(new Func<bool>(delegate { return box.Focused; })) }));
                                    composition.Begin(message.session);
                                }
                                if (message.type == "update") {
                                    composition.Update(message.session, message.text); updates++;
                                    writer.WriteLine(json.Serialize(new { characters = message.text.Length }));
                                }
                                if (message.type == "end") {
                                    composition.End();
                                    string text = (string)box.Invoke(new Func<string>(delegate { return box.Text; }));
                                    File.WriteAllText(args[0], json.Serialize(new { pass = text == "prefix 今天下午两点开会", text, updates }));
                                    break;
                                }
                            }
                        }
                    }
                } catch (Exception e) { File.WriteAllText(args[0], json.Serialize(new { pass = false, error = e.Message })); }
                finally { listener.Stop(); if (!form.IsDisposed) form.BeginInvoke(new Action(form.Close)); }
            }) { IsBackground = true }.Start();
        };
        Application.Run(form); timeout.Dispose();
    }
}
