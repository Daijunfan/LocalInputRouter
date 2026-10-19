// Disposable Windows UI for the Mac routing integration fixture. Exits in 90s.
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class PointerRoutingProbe : Form {
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    readonly string folder;
    readonly DateTime began = DateTime.UtcNow;
    readonly Timer timer = new Timer { Interval = 100 };
    Rectangle initial;
    int enters, exits;
    string command = "";
    PointerRoutingProbe(string path) {
        folder = path;
        Text = "InputRouter pointer check - closes automatically";
        StartPosition = FormStartPosition.Manual;
        Bounds = new Rectangle(700, 400, 600, 260);
        TopMost = true;
        Controls.Add(new Label { Text = "Disposable drag test", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter });
        timer.Tick += delegate {
            string file = Path.Combine(folder, "command.txt");
            string next = File.Exists(file) ? File.ReadAllText(file).Trim() : "";
            if (next != command) {
                command = next;
                if (next == "prepare") {
                    var p = Cursor.Position;
                    Location = new Point(p.X - 150, p.Y - 15);
                    initial = Bounds;
                    enters = exits = 0;
                    Activate();
                }
            }
            var cursor = Cursor.Position;
            var data = new { cursorX = cursor.X, cursorY = cursor.Y,
                leftDown = GetAsyncKeyState(1) < 0, x = Left, y = Top,
                initialX = initial.X, initialY = initial.Y, enters, exits,
                moved = initial.Width > 0 && Bounds.Location != initial.Location,
                screenWidth = Screen.PrimaryScreen.Bounds.Width, screenHeight = Screen.PrimaryScreen.Bounds.Height };
            File.WriteAllText(Path.Combine(folder, "result.json"), new JavaScriptSerializer().Serialize(data));
            if (command == "close" || (DateTime.UtcNow - began).TotalSeconds > 90) Close();
        };
        Shown += delegate { initial = Bounds; timer.Start(); };
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x231) enters++;
        if (m.Msg == 0x232) exits++;
        base.WndProc(ref m);
    }
    [STAThread] static void Main(string[] args) {
        Application.EnableVisualStyles();
        Application.Run(new PointerRoutingProbe(args[0]));
    }
}
