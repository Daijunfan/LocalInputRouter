import AppKit
import Network

/// Clipboard traffic has its own authenticated SSH stream and no disk history.
@MainActor final class ClipboardBridge {
    private let board: NSPasteboard
    private let port: NWEndpoint.Port
    private let codec = DispatchQueue(label: "org.localinputrouter.app.clipboard.codec", qos: .utility)
    private var connection: NWConnection?
    private var timer: Timer?
    private var buffer = Data(), token = "", appliedID = ""
    private var running = false, networkReady = false, ready = false, encoding = false
    private var lastChange = -1, generation = 0
    private(set) var sent = 0, received = 0
    var onState: ((Bool, String) -> Void)?

    init(board: NSPasteboard = .general, port: UInt16 = 24904) {
        self.board = board; self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start(tokenURL: URL) {
        stop()
        guard let secret = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            onState?(false, "剪贴板认证尚未配置"); return
        }
        running = true; token = secret; connect()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }
    func stop() {
        generation += 1; running = false; networkReady = false; ready = false; encoding = false
        timer?.invalidate(); timer = nil; connection?.cancel(); connection = nil; buffer.removeAll()
        onState?(false, "剪贴板共享未连接")
    }
    private func connect() {
        guard running else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let c = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection = c; buffer.removeAll(); lastChange = -1; appliedID = ""
        c.stateUpdateHandler = { [weak self, weak c] state in
            MainActor.assumeIsolated {
                guard let self, let c, self.connection === c else { return }
                switch state {
                case .ready:
                    self.networkReady = true
                    self.sendCurrent(c, initial: true); self.receive(c)
                case .failed, .waiting: self.retry(c)
                default: break
                }
            }
        }
        c.start(queue: .main)
    }
    private func retry(_ c: NWConnection) {
        guard connection === c else { return }
        generation += 1; c.cancel(); connection = nil
        ready = false; networkReady = false; encoding = false
        onState?(false, "剪贴板共享正在重连")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running, self.connection == nil else { return }; self.connect()
        }
    }
    private func poll() {
        guard networkReady, !encoding, let c = connection, board.changeCount != lastChange else { return }
        if ready && !appliedID.isEmpty && board.string(forType: MacClipboard.marker) == appliedID {
            lastChange = board.changeCount; return
        }
        sendCurrent(c, initial: !ready)
    }
    private func sendCurrent(_ c: NWConnection, initial: Bool) {
        let count = board.changeCount, epoch = generation
        let captured = MacClipboard.capture(board), secret = initial ? token : nil
        encoding = true; lastChange = count
        codec.async { [weak self, weak c] in
            let packet = MacClipboard.encode(captured)
            var message: [String: Any] = ["clipboard": packet]
            if let secret { message["hello"] = secret }
            let data = try? JSONSerialization.data(withJSONObject: message)
            DispatchQueue.main.async {
                guard let self, let c, self.generation == epoch, self.connection === c else { return }
                self.encoding = false
                if self.board.changeCount != count { self.sendCurrent(c, initial: initial); return }
                if let data, self.write(data, c) { self.sent += 1 }
            }
        }
    }
    private func write(_ payload: Data, _ c: NWConnection) -> Bool {
        var data = payload
        guard data.count <= 64 * 1024 * 1024 else {
            onState?(ready, "剪贴板内容超过 64 MB，未同步"); return false
        }
        data.append(10)
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] error in
            DispatchQueue.main.async { if error != nil, let c { self?.retry(c) } }
        })
        return true
    }
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, ended, error in
            MainActor.assumeIsolated {
                guard let self, let c, self.connection === c else { return }
                if let data { self.buffer.append(data) }
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer[..<end]); self.buffer.removeSubrange(...end)
                    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if value["ready"] as? Bool == true {
                        self.ready = true; self.onState?(true, "剪贴板已共享 · 文字、图片与富文本")
                    }
                    if let fields = value["clipboard"] as? [String: Any] {
                        let packet = fields.compactMapValues { $0 as? String }
                        MacClipboard.apply(packet, to: self.board)
                        self.appliedID = packet["id"] ?? ""; self.lastChange = self.board.changeCount
                        self.received += 1
                    }
                    if let message = value["error"] as? String { self.onState?(self.ready, "剪贴板同步失败：" + message) }
                }
                if ended || error != nil { self.retry(c) } else { self.receive(c) }
            }
        }
    }
}

enum MacClipboard {
    static let marker = NSPasteboard.PasteboardType("org.localinputrouter.app.clipboard-id")
    struct Captured { var packet: [String: String]; let tiff: Data? }
    static func capture(_ board: NSPasteboard) -> Captured {
        var packet = ["id": UUID().uuidString]
        if let text = board.string(forType: .string) { packet["text"] = text }
        if let html = board.string(forType: .html) { packet["html"] = html }
        if let rtf = board.data(forType: .rtf) { packet["rtf"] = rtf.base64EncodedString() }
        let png = board.data(forType: .png)
        if let png { packet["png"] = png.base64EncodedString() }
        return Captured(packet: packet, tiff: png == nil ? board.data(forType: .tiff) : nil)
    }
    static func encode(_ captured: Captured) -> [String: String] {
        var packet = captured.packet
        if let tiff = captured.tiff, let image = NSBitmapImageRep(data: tiff),
           let png = image.representation(using: .png, properties: [:]) { packet["png"] = png.base64EncodedString() }
        return packet
    }
    static func apply(_ packet: [String: String], to board: NSPasteboard) {
        let item = NSPasteboardItem()
        for (key, type) in [("text", NSPasteboard.PasteboardType.string), ("html", .html)] {
            if let value = packet[key] { item.setString(value, forType: type) }
        }
        for (key, type) in [("rtf", NSPasteboard.PasteboardType.rtf), ("png", .png)] {
            if let value = packet[key], let bytes = Data(base64Encoded: value) { item.setData(bytes, forType: type) }
        }
        if let id = packet["id"] { item.setString(id, forType: marker) }
        board.clearContents(); board.writeObjects([item])
    }
}
