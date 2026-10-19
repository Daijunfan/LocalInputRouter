import AppKit
import Network

@main @MainActor enum VoiceRoutingLive {
    static func main() {
        _ = NSApplication.shared
        let voice = VoiceBridge()
        let transport = VoiceTransport(port: 24813)
        var session = "", acknowledged: [Int] = [], error = "", started = false
        voice.onBegin = { session = $0; transport.send(type: "begin", session: $0) }
        voice.onUpdate = { transport.send(type: "update", session: $0, text: $1) }
        voice.onCancel = { transport.send(type: "cancel", session: $0) }
        transport.onError = { error = $0 }
        transport.onAcknowledged = { acknowledged.append($0) }
        transport.onReady = { ready in
            guard ready, !started else { return }; started = true
            guard voice.prepare(), let view = NSApp.windows
                .flatMap({ $0.contentView?.subviews ?? [] }).compactMap({ $0 as? VoiceTextView }).first else {
                error = "Could not prepare the app-owned speech field"; return
            }
            for text in ["今天", "今天下五", "今天下午"] {
                view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            view.insertText("今天下午两点开会", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DJF Input Router")
        transport.start(tokenURL: support.appendingPathComponent("trackpad-token"))
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, error.isEmpty, acknowledged.count < 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let snapshot = voice.snapshot
        transport.send(type: "end", session: session)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        voice.leave(); transport.stop()
        let pass = error.isEmpty && acknowledged.count >= 4 && acknowledged.last == "今天下午两点开会".utf16.count
        let result: [String: Any] = ["pass": pass, "acknowledgedCharacters": acknowledged,
            "speechField": snapshot, "error": error]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        if !pass { exit(1) }
    }
}
