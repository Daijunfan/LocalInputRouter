import Foundation
import Network

/// Speech text has its own stream, so editor updates cannot delay gestures.
final class VoiceTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.localinputrouter.app.voice", qos: .userInteractive)
    private var connection: NWConnection?
    private var buffer = Data(), token = ""
    private var running = false
    var onReady: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onAcknowledged: ((Int) -> Void)?

    func start(tokenURL: URL) {
        stop()
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        queue.async { self.running = true; self.token = token; self.connect() }
    }
    func stop() {
        queue.sync { running = false; connection?.cancel(); connection = nil; buffer.removeAll() }
        onReady?(false)
    }
    func send(type: String, session: String, text: String = "") {
        queue.async { self.write(["type":type,"session":session,"text":text]) }
    }
    private func write(_ object: [String:Any]) {
        guard let connection, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            if error != nil, let connection { self?.retry(connection) }
        })
    }
    private func connect() {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let c = NWConnection(host: "127.0.0.1", port: 24903, using: NWParameters(tls: nil, tcp: tcp))
        connection = c; buffer.removeAll()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.connection === c else { return }
            switch state {
            case .ready: self.write(["hello":self.token]); self.receive(c)
            case .failed, .waiting: self.retry(c)
            default: break
            }
        }
        c.start(queue: queue)
    }
    private func retry(_ c: NWConnection) {
        guard connection === c else { return }
        c.cancel(); connection = nil
        DispatchQueue.main.async { [weak self] in self?.onReady?(false) }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running, self.connection == nil else { return }; self.connect()
        }
    }
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak c] data, _, ended, error in
            guard let self, let c, self.connection === c else { return }
            if let data { self.buffer.append(data) }
            while let end = self.buffer.firstIndex(of: 10) {
                let line = Data(self.buffer[..<end]); self.buffer.removeSubrange(...end)
                guard let value = try? JSONSerialization.jsonObject(with: line) as? [String:Any] else { continue }
                DispatchQueue.main.async { [weak self] in
                    if value["ready"] as? Bool == true { self?.onReady?(true) }
                    if let count = value["characters"] as? Int { self?.onAcknowledged?(count) }
                    if let message = value["error"] as? String { self?.onError?(message) }
                }
            }
            if ended || error != nil { self.retry(c) } else { self.receive(c) }
        }
    }
}
