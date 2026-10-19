import AppKit
import WebKit
import Network

/// App-owned console viewer. Credentials stay in memory; authentication has no modal UI.
@MainActor
final class ConsoleWindow: NSWindowController, NSWindowDelegate, WKScriptMessageHandler {
    private let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var connection: NWConnection?
    private let password: String
    var onStatus: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(password: String) {
        self.password = password
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DJF-Windows"
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = web
        window.center()
        web.configuration.userContentController.add(self, name: "console")
        load()
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(web)
    }

    private func load() {
        disconnect()
        guard let resource = Bundle.main.url(forResource: "console-viewer", withExtension: "js"),
              let script = try? String(contentsOf: resource, encoding: .utf8),
              let credentials = try? JSONSerialization.data(withJSONObject: [password]) else {
            onStatus?("共享桌面组件尚未安装"); return
        }
        let encoded = String(decoding: credentials, as: UTF8.self)
        let html = """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;width:100%;height:100%;background:#101418;color:#eee;font:13px system-ui}
        #desktop{position:absolute;inset:0 0 32px}canvas{cursor:none!important}
        footer{position:absolute;bottom:0;left:0;right:0;height:32px;display:flex;align-items:center;gap:16px;padding:0 12px}
        button{margin-left:auto} </style>
        <div id="desktop" aria-label="DJF-Windows 共享实体桌面"></div>
        <footer><span id="status" role="status">正在连接 DJF-Windows…</span><button id="reconnect">重新连接</button></footer>
        <script type="module">\(script.replacingOccurrences(of: "</script", with: "<\\/script"))
        window.startDJFConsole(\(encoded)[0]);</script>
        """
        web.loadHTMLString(html, baseURL: URL(string: "http://localhost/"))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let operation = body["op"] as? String else { return }
        switch operation {
        case "start": connect()
        case "send":
            if let encoded = body["bytes"] as? String, let bytes = Data(base64Encoded: encoded) {
                connection?.send(content: bytes, completion: .contentProcessed { _ in })
            }
        case "close": disconnect()
        case "restart": load()
        case "status": if let text = body["text"] as? String { onStatus?(text) }
        default: break
        }
    }

    private func connect() {
        disconnect()
        let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(ConsoleDesktop.port))!, using: .tcp)
        connection = socket
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            MainActor.assumeIsolated {
                guard let self, let socket, self.connection === socket else { return }
                switch state {
                case .ready:
                    self.web.evaluateJavaScript("djfConsole.open()") { [weak self] _, _ in self?.receive(socket) }
                case .failed:
                    self.onStatus?("共享桌面连接已断开")
                    self.disconnect()
                    self.web.evaluateJavaScript("djfConsole.end()", completionHandler: nil)
                default: break
                }
            }
        }
        socket.start(queue: .main)
    }

    private func receive(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak socket] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let socket, self.connection === socket else { return }
                if let data, !data.isEmpty {
                    self.web.evaluateJavaScript("djfConsole.receive('\(data.base64EncodedString())')") { [weak self] _, failure in
                        guard let self, self.connection === socket else { return }
                        if failure != nil { self.onStatus?("共享画面解码失败"); self.disconnect() }
                        else { self.receive(socket) }
                    }
                } else if complete || error != nil {
                    self.disconnect()
                    self.web.evaluateJavaScript("djfConsole.end()", completionHandler: nil)
                } else { self.receive(socket) }
            }
        }
    }

    private func disconnect() {
        connection?.cancel(); connection = nil
    }
    func measureFrame(_ completed: @escaping ([String: Any]) -> Void) {
        let script = """
        (()=>{const c=document.querySelector('canvas');if(!c)return {width:0,height:0,nonBlack:0};
        const p=c.getContext('2d').getImageData(0,0,c.width,c.height).data;let n=0;
        for(let i=0;i<p.length;i+=64)if(p[i+3]>0&&(p[i]>12||p[i+1]>12||p[i+2]>12))n++;
        return {width:c.width,height:c.height,nonBlack:n,samples:Math.ceil(p.length/64),status:document.getElementById('status').textContent}})()
        """
        web.evaluateJavaScript(script) { value, error in
            completed(value as? [String: Any] ?? ["error": error?.localizedDescription ?? "No console frame"])
        }
    }
    func windowWillClose(_ notification: Notification) {
        disconnect()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "console")
        onClose?()
    }
}
