import Foundation
import Network

private weak var contactOwner: TrackpadBridge?

/// Native contacts use a separate authenticated SSH-forwarded channel.
/// Deskflow remains responsible for keys, pointer movement and clicks.
final class TrackpadBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.djf.inputrouter.contacts", qos: .userInteractive)
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var token = ""
    private var width = 0, height = 0
    private var running = false, ready = false, routing = false
    private var macScroll = false, scrollEvents = 0
    private var deleteKey = false
    private var peakFingers = 0, touchStart = 0.0, maxDistance = 0.0
    private var starts: [Int32: (Double, Double)] = [:]
    private var sentFrames = 0, maximumContacts = 0
    private var capturedFrames = 0, capturedContacts = 0
    private var frameGate = GestureFrameGate()
    private var skippedFrames = 0
    private var pingStarted: Double?
    private var capturing = false
    private var tapToggle = ThreeFingerDoubleTap()
    private var switchGesture = TouchSwitchGesture.threeDouble
    private var tapGeneration = 0, tapToggles = 0
    private var roundTrips: [Double] = []
    var onState: ((Bool, String) -> Void)?
    var onContacts: ((Int) -> Void)?
    var onTouchFrame: ((Int, Double, Double, Double) -> Void)?
    var onScrollReady: ((Bool) -> Void)?
    var onDeleteReady: ((Bool) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onTapReservation: ((Bool) -> Void)?

    func setSwitchGesture(_ gesture: TouchSwitchGesture) {
        queue.sync {
            switchGesture = gesture; tapToggle = ThreeFingerDoubleTap(mode: gesture)
            tapGeneration += 1; onTapReservation?(false)
        }
    }

    func startCapture() {
        guard !capturing else { return }
        contactOwner = self
        guard DJFStartTrackpad({ contacts, count, time in
            guard let owner = contactOwner else { return }
            // Release/arm dragging immediately, before JSON work and socket IO.
            owner.onTouchFrame?(Int(count), contacts?.pointee.x ?? 0, contacts?.pointee.y ?? 0, time)
            let copy = contacts.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) } ?? []
            owner.queue.async { owner.frame(copy, at: time) }
        }) != 0 else { onState?(false, "无法读取内建触控板"); return }
        capturing = true
    }
    func stopCapture() {
        DJFStopTrackpad(); capturing = false
        if contactOwner === self { contactOwner = nil }
        queue.sync { tapToggle = ThreeFingerDoubleTap(mode: switchGesture); tapGeneration += 1; onTapReservation?(false) }
    }
    func start(tokenURL: URL) {
        stop(); startCapture()
        guard let secret = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            onState?(false, "多指触控尚未配置"); return
        }
        let w = Int(DJFTrackpadWidth()), h = Int(DJFTrackpadHeight())
        queue.async {
            self.running = true; self.token = secret; self.width = w; self.height = h
            self.connect()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                guard let self, self.ready else { return }
                if let started = self.pingStarted {
                    if ProcessInfo.processInfo.systemUptime - started > 2, let c = self.connection {
                        self.retry(c, message: "原生触控响应超时，正在重连")
                    }
                    return
                }
                self.pingStarted = ProcessInfo.processInfo.systemUptime
                self.send(["type": "ping"])
            }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        queue.sync {
            running = false; routing = false
            send(["type": "reset"])
            connection?.cancel(); connection = nil
            timer?.cancel(); timer = nil; ready = false; macScroll = false; deleteKey = false; buffer.removeAll(); clearGesture()
            pingStarted = nil; roundTrips.removeAll()
            onScrollReady?(false)
            onDeleteReady?(false)
            onContacts?(0)
        }
    }
    func scroll(x: Double, y: Double, begin: Bool) {
        queue.async {
            guard self.routing, self.ready, self.macScroll else { return }
            self.send(["type":"scroll", "x":x, "y":y, "begin":begin])
            self.scrollEvents += 1
        }
    }
    func setRouting(_ enabled: Bool) {
        queue.async {
            guard self.routing != enabled else { return }
            self.routing = enabled; self.clearGesture()
            if !enabled { self.send(["type": "reset"]); self.onContacts?(0) }
        }
    }
    func delete() {
        queue.async {
            guard self.ready, self.deleteKey else { return }
            self.send(["type": "delete"])
        }
    }
    var snapshot: [String: Any] {
        queue.sync { ["ready": ready, "frames": sentFrames, "maxContacts": maximumContacts,
                      "width": width, "height": height, "capturedFrames": capturedFrames, "capturedContacts": capturedContacts, "macScroll": macScroll, "scrollEvents": scrollEvents,
                      "roundTripMedianMs": roundTrips.isEmpty ? -1 : roundTrips.sorted()[roundTrips.count / 2],
                      "roundTripMaxMs": roundTrips.max() ?? -1, "skippedSingleFingerFrames": skippedFrames,
                      "captureActive": capturing, "doubleTapToggles": tapToggles, "deleteKey": deleteKey] }
    }
    private func connect() {
        guard running else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let c = NWConnection(host: "127.0.0.1", port: 24801, using: NWParameters(tls: nil, tcp: tcp))
        connection = c; buffer.removeAll(); pingStarted = nil; roundTrips.removeAll()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.connection === c else { return }
            switch state {
            case .ready:
                self.send(["hello": self.token, "width": self.width, "height": self.height, "macScroll":true], handshake: true)
                self.receive(c)
            case .failed, .waiting: self.retry(c, message: "正在连接 Windows 原生触控板")
            default: break
            }
        }
        c.start(queue: queue)
    }
    private func retry(_ c: NWConnection, message: String) {
        guard connection === c else { return }
        c.cancel(); connection = nil; ready = false; macScroll = false; deleteKey = false; clearGesture(); onContacts?(0); onScrollReady?(false); onDeleteReady?(false)
        DispatchQueue.main.async { [weak self] in self?.onState?(false, message) }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running, self.connection == nil else { return }; self.connect()
        }
    }
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak c] data, _, ended, error in
            guard let self, let c, self.connection === c else { return }
            if let data { self.buffer.append(data) }
            while let index = self.buffer.firstIndex(of: 10) {
                let line = Data(self.buffer[..<index]); self.buffer.removeSubrange(...index)
                guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if value["pong"] as? Bool == true, let began = self.pingStarted {
                    self.roundTrips.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
                    if self.roundTrips.count > 20 { self.roundTrips.removeFirst() }
                    self.pingStarted = nil
                }
                if value["ready"] as? Bool == true {
                    self.ready = true
                    self.macScroll = value["macScroll"] as? Bool == true
                    self.deleteKey = value["deleteKey"] as? Bool == true
                    self.onScrollReady?(self.macScroll)
                    self.onDeleteReady?(self.deleteKey)
                    DispatchQueue.main.async { [weak self] in self?.onState?(true, "Windows 原生多指触控已连接") }
                }
                if let failure = value["error"] as? String { self.retry(c, message: "原生触控暂不可用：" + failure); return }
            }
            if ended || error != nil { self.retry(c, message: "原生触控断开，正在重连") }
            else { self.receive(c) }
        }
    }
    private func send(_ object: [String: Any], handshake: Bool = false) {
        guard let c = connection, ready || handshake,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, error != nil else { return }
            self.retry(c, message: "原生触控发送中断，正在重连")
        })
    }
    private func clearGesture() { peakFingers = 0; touchStart = 0; maxDistance = 0; starts.removeAll(); frameGate.reset() }
    private func frame(_ contacts: [DJFContact], at time: Double) {
        capturedFrames += 1; capturedContacts = max(capturedContacts, contacts.count)
        switch tapToggle.frame(contacts.map { ($0.id, $0.x, $0.y) }, time: time) {
        case .first:
            tapGeneration += 1
            let generation = tapGeneration, wasRemote = routing && ready
            queue.asyncAfter(deadline: .now() + ThreeFingerDoubleTap.interval) { [weak self] in
                guard let self, generation == self.tapGeneration else { return }
                self.tapToggle.expire(); self.onTapReservation?(self.tapToggle.reserving)
                if wasRemote && self.routing && self.ready { self.send(["type":"action", "action":0]) }
            }
        case .toggle:
            tapGeneration += 1; tapToggles += 1
            DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
        case .none: break
        }
        onTapReservation?(tapToggle.reserving)
        guard running, routing, ready else { return }
        if touchStart == 0 && !contacts.isEmpty {
            touchStart = time
            send(["type": "action", "action": 9]) // Touching the pad stops remote content inertia.
        }
        peakFingers = max(peakFingers, contacts.count)
        for c in contacts {
            if let start = starts[c.id] { maxDistance = max(maxDistance, hypot(c.x - start.0, c.y - start.1)) }
            else { starts[c.id] = (c.x, c.y) }
        }
        if frameGate.shouldSend(count: contacts.count) {
            let gestureContacts = contacts.count >= 2 ? contacts : []
            send(["type": "frame", "touches": gestureContacts.map { ["id": $0.id, "x": $0.x, "y": $0.y] as [String: Any] }])
            sentFrames += 1; maximumContacts = max(maximumContacts, contacts.count)
        } else { skippedFrames += 1 }
        if contacts.isEmpty && touchStart != 0 {
            // Windows' gesture-only device leaves discrete multi-finger taps to its caller.
            if time - touchStart < 0.3 && maxDistance < 0.025 {
                if peakFingers == 3 && switchGesture == .fourSingle { send(["type": "action", "action": 0]) }
                if (4...5).contains(peakFingers) && !(peakFingers == 4 && switchGesture == .fourSingle) {
                    send(["type": "action", "action": (peakFingers - 3) * 3])
                }
            }
            clearGesture()
        }
    }
}
