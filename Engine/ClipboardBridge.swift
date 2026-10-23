import AppKit
import Network

/// Clipboard traffic has its own authenticated SSH stream and no disk history.
@MainActor final class ClipboardBridge {
    private let board: NSPasteboard
    private let port: NWEndpoint.Port
    private let pingInterval: TimeInterval, stallTimeout: TimeInterval
    private let codec = DispatchQueue(label: "com.djf.inputrouter.clipboard.codec", qos: .utility)
    private var connection: NWConnection?
    private var timer: Timer?
    private var buffer = Data(), token = "", appliedID = "", pendingID = ""
    private var lastPayload = [String: String]()
    private var running = false, networkReady = false, ready = false, encoding = false
    private var lastChange = -1, generation = 0
    private var lastPing = Date.distantPast, lastPong = Date.distantPast
    private(set) var sent = 0, received = 0
    var onState: ((Bool, String) -> Void)?

    init(board: NSPasteboard = .general, port: UInt16 = 24804,
         pingInterval: TimeInterval = 3, stallTimeout: TimeInterval = 15) {
        self.board = board; self.port = NWEndpoint.Port(rawValue: port)!
        self.pingInterval = pingInterval; self.stallTimeout = stallTimeout
    }

    func start(tokenURL: URL) {
        stop()
        guard let secret = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            onState?(false, "剪贴板认证尚未配置"); return
        }
        running = true; token = secret; connect()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func stop() {
        generation += 1; running = false; networkReady = false; ready = false; encoding = false
        pendingID = ""; lastPayload.removeAll()
        lastPing = .distantPast; lastPong = .distantPast
        timer?.invalidate(); timer = nil; connection?.cancel(); connection = nil; buffer.removeAll()
        onState?(false, "剪贴板共享未连接")
    }
    private func connect() {
        guard running else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let c = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection = c; buffer.removeAll(); lastChange = -1; appliedID = ""
        pendingID = ""; lastPayload.removeAll()
        lastPing = .distantPast; lastPong = .distantPast
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
        pendingID = ""
        lastPing = .distantPast; lastPong = .distantPast
        onState?(false, "剪贴板共享正在重连")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running, self.connection == nil else { return }; self.connect()
        }
    }
    private func tick() {
        guard running, networkReady, let c = connection else { return }
        // TCP can stay "connected" after the receiver's clipboard STA stops pumping.
        // The receiver answers these probes from that STA, not its socket reader.
        if ready {
            let now = Date()
            if now.timeIntervalSince(lastPong) > stallTimeout {
                retry(c); return
            }
            if now.timeIntervalSince(lastPing) >= pingInterval {
                lastPing = now
                if let payload = try? JSONSerialization.data(withJSONObject: ["ping": UUID().uuidString]) {
                    _ = write(payload, c)
                }
            }
        }
        poll()
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
                let payload = packet.filter { $0.key != "id" }
                if captured.needsNativeImage && packet["png"] != nil {
                    MacClipboard.apply(packet, to: self.board)
                    self.appliedID = packet["id"] ?? ""; self.lastChange = self.board.changeCount
                }
                if !initial && payload == self.lastPayload { return }
                if let data, self.write(data, c) {
                    self.pendingID = packet["id"] ?? ""
                    self.lastPayload = payload; self.sent += 1
                }
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
                if self.buffer.count > 64 * 1024 * 1024 + 1 {
                    self.retry(c); return
                }
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer[..<end]); self.buffer.removeSubrange(...end)
                    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if value["ready"] as? Bool == true {
                        self.ready = true
                        if value["ack"] == nil { self.pendingID = "" } // Older receivers acknowledge the initial copy with ready.
                        self.lastPong = Date()
                        self.onState?(true, "剪贴板已共享 · 文字、图片与富文本")
                    }
                    if value["pong"] as? String != nil { self.lastPong = Date() }
                    if let ack = value["ack"] as? String, ack == self.pendingID { self.pendingID = "" }
                    if let fields = value["clipboard"] as? [String: Any] {
                        // The receiver queues copies before the acknowledgement of our newer copy.
                        // Do not let an older in-flight copy overwrite local capture/encoding.
                        if self.encoding || !self.pendingID.isEmpty || self.board.changeCount != self.lastChange {
                            self.poll(); continue
                        }
                        let packet = fields.compactMapValues { $0 as? String }
                        let payload = packet.filter { $0.key != "id" }
                        if payload == self.lastPayload { continue }
                        MacClipboard.apply(packet, to: self.board)
                        self.lastPayload = payload
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
    static let marker = NSPasteboard.PasteboardType("com.djf.inputrouter.clipboard-id")
    struct Captured { var packet: [String: String]; let tiff: Data?; let needsNativeImage: Bool }
    static func capture(_ board: NSPasteboard) -> Captured {
        var packet = ["id": UUID().uuidString]
        if let text = board.string(forType: .string) { packet["text"] = text }
        if let html = board.string(forType: .html) { packet["html"] = html }
        if let rtf = board.data(forType: .rtf) { packet["rtf"] = rtf.base64EncodedString() }
        let types = board.pasteboardItems?.flatMap(\.types) ?? []
        let png = board.data(forType: .png)
        let validPNG = png?.starts(with: [137,80,78,71,13,10,26,10]) == true
        if validPNG, let png { packet["png"] = png.base64EncodedString() }
        // A native RDP item can advertise PNG while returning TIFF bytes, or
        // leave TIFF implicit. Materialize both locally, including duplicate
        // images that do not need another network transfer.
        let native = types.contains(.png) && (!types.contains(.tiff) || !validPNG) && !types.contains(.fileURL)
        return Captured(packet: packet, tiff: validPNG ? nil : (png ?? board.data(forType: .tiff)), needsNativeImage: native)
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
            if let value = packet[key], let bytes = Data(base64Encoded: value) {
                item.setData(bytes, forType: type)
                // Explicit native TIFF prevents Electron from exposing synthesized TIFF bytes as image/png.
                if type == .png, let tiff = NSBitmapImageRep(data: bytes)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            }
        }
        if let id = packet["id"] { item.setString(id, forType: marker) }
        board.clearContents(); board.writeObjects([item])
    }
}
