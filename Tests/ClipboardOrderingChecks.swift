import AppKit
import Network

@main @MainActor enum ClipboardOrderingChecks {
    static func main() throws {
        var failures = [String]()
        func check(_ passed: Bool, _ message: String) {
            if !passed { failures.append(message); print("FAIL: " + message) }
        }
        func wait(_ seconds: Double = 0.15) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func until(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { wait(0.02) }
            return condition()
        }
        let board = NSPasteboard(name: .init("com.djf.clipboard.check." + UUID().uuidString))
        let token = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "isolated-test-token".write(to: token, atomically: true, encoding: .utf8)
        let listener = try NWListener(using: .tcp, on: .any)
        var peer: NWConnection?, input = Data(), packets = [[String: Any]]()
        func send(_ value: [String: Any]) {
            var data = try! JSONSerialization.data(withJSONObject: value); data.append(10)
            peer!.send(content: data, completion: .contentProcessed { _ in })
        }
        func receive(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, ended, error in
                MainActor.assumeIsolated {
                    if let data { input.append(data) }
                    while let end = input.firstIndex(of: 10) {
                        let line = Data(input[..<end]); input.removeSubrange(...end)
                        let value = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
                        if let packet = value["clipboard"] as? [String: Any] {
                            packets.append(packet)
                            if value["hello"] != nil { send(["ready": true, "ack": packet["id"]!]) }
                        }
                        if let ping = value["ping"] { send(["pong": ping]) }
                    }
                    if !ended && error == nil { receive(connection) }
                }
            }
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                peer = connection; connection.start(queue: .main); receive(connection)
            }
        }
        listener.start(queue: .main)
        guard until({ listener.port != nil }) else { throw NSError(domain: "listener", code: 1) }
        board.setString("initial", forType: .string)
        let bridge = ClipboardBridge(board: board, port: listener.port!.rawValue)
        var ready = false; bridge.onState = { ready = $0; _ = $1 }
        bridge.start(tokenURL: token)
        check(until({ ready }), "isolated clipboard handshake")
        board.clearContents(); board.setString("new local copy", forType: .string)
        check(until({ packets.count == 2 }), "local copy reaches peer")
        let pending = packets.last!["id"]!
        send(["ack": "not-the-current-copy"])
        send(["clipboard": ["id": "older-in-flight", "text": "old remote copy"]])
        wait()
        check(board.string(forType: .string) == "new local copy", "in-flight remote copy must not overwrite unacknowledged local copy")
        send(["ack": pending])
        send(["clipboard": ["id": "later-remote", "text": "later remote copy"]])
        check(until({ board.string(forType: .string) == "later remote copy" }), "remote copy after acknowledgement is applied")
        let receivedCount = packets.count
        wait()
        check(packets.count == receivedCount, "received clipboard is not echoed")

        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<2 { for x in 0..<3 { image.setColor(NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.9, alpha: x == 0 ? 0.5 : 1), atX: x, y: y) } }
        let png = image.representation(using: .png, properties: [:])!
        send(["clipboard": ["id": "image-fixture", "png": png.base64EncodedString()]])
        check(until({ board.data(forType: .png) == png }), "remote PNG is applied through the shared clipboard connection")
        check(board.string(forType: .string) == nil, "image replaces old text")
        check(board.data(forType: .png) == png, "original PNG is preserved")
        let declared = board.pasteboardItems?.first?.types ?? []
        check(declared.contains(.png) && declared.contains(.tiff), "PNG and TIFF must both be explicitly declared, not synthesized during paste")
        let tiff = board.data(forType: .tiff).flatMap(NSBitmapImageRep.init(data:))
        check(tiff?.pixelsWide == 3 && tiff?.pixelsHigh == 2, "image exposes a native TIFF representation for paste previews")
        check(tiff?.colorAt(x: 0, y: 0)?.alphaComponent ?? 0 > 0.45, "native image keeps alpha")
        check(tiff?.colorAt(x: 0, y: 0)?.alphaComponent ?? 1 < 0.55, "native image keeps translucent pixels")
        bridge.stop(); peer?.cancel(); listener.cancel(); board.releaseGlobally()
        try? FileManager.default.removeItem(at: token)
        print(failures.isEmpty ? "PASS: clipboard ordering, echo isolation and native PNG/TIFF image paste" : "FAILED: \(failures.count) clipboard checks")
        exit(failures.isEmpty ? 0 : 1)
    }
}
