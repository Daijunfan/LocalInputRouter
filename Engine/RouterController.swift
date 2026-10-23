import AppKit
import ApplicationServices
import Carbon
import Combine
import Network
import IOKit.pwr_mgt
import Darwin

enum RouterTransport: String, CaseIterable {
    case direct, bluetooth
    var title: String { self == .direct ? "局域网（自动）" : "蓝牙直连" }
    var detail: String {
        self == .direct ? "优先在当前局域网直连；失败时尝试备用 IP，再查询登记地址。" : "通过已配对的蓝牙连接；Mac 继续使用 Wi-Fi 上网。"
    }
}

@MainActor
final class RouterController: ObservableObject {
    @Published var destination = InputDestination.mac
    @Published var connected = false
    @Published var status = "准备连接 DJF-Windows"
    @Published var address = ""
    @Published private(set) var transport = RouterTransport(rawValue: UserDefaults.standard.string(forKey: "transport") ?? "direct") ?? .direct
    private let bluetoothAddress = "44:F7:9F:A3:BC:44"
    private var cachedAddress = UserDefaults.standard.string(forKey: "windowsAddress") ?? ""
    @Published private(set) var lanAddress = UserDefaults.standard.string(forKey: "lanAddress") ?? ""
    @Published private(set) var desktopMode = RemoteDesktopMode(rawValue: UserDefaults.standard.string(forKey: "desktopMode") ?? "rdp") ?? .rdp
    @Published private(set) var consoleStatus = "共享实体桌面让 Windows USB 键盘与远程画面操作同一桌面。"
    @Published private(set) var openingConsole = false
    private var consoleRequest: Process?
    @Published var accessibility = false
    @Published var monitoring = false
    @Published var displayAvailable = false
    @Published var running = true
    @Published var pendingDestination: InputDestination?
    @Published var toggleShortcut = RouterShortcut.toggle
    @Published var emergencyShortcut = RouterShortcut.emergency
    @Published private(set) var switchGesture = TouchSwitchGesture(rawValue: UserDefaults.standard.string(forKey: "switchGesture") ?? "") ?? .threeDouble
    @Published private(set) var pointerGain = 1.0
    @Published private(set) var scrollGain = 1.5
    @Published private(set) var dragTapInterval = 0.20
    private var engine: Process?
    private var tunnel: Process?
    private var lookup: Process?
    private var directProbes: [Process] = []
    private var probeGeneration = 0
    private var guardian: Process?
    private var ipc: NWConnection?
    private var ipcBuffer = Data()
    private var ipcLastReply: Date?
    private var logBuffer = ""
    private var backendLog: FileHandle?
    private var clientDeadline: Date?
    private var receiverRepair: Process?
    private var receiverRepairRequested = false
    private var desired = InputDestination.mac
    private var nextRetry = Date.distantPast
    private var retryCount = 0
    private var networkSignature = ""
    private var networkObserved = false
    @Published private(set) var usingConfiguredSSH = false
    var connectionRoute: String {
        transport == .direct ? (usingConfiguredSSH ? "局域网经 SSH 跳板" : "局域网直连") : transport.title
    }
    private var timer: Timer?
    private var commandObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var lastStateSummary = ""
    private var connectionStarted = Date()
    private var connectionMilliseconds = 0.0
    private var activity: NSObjectProtocol?
    private var rdpPointer = false
    private var rdpFrontmost = ""
    private var rdpWindowTitle = ""
    private var previousRDPApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    private var rdpActivation = ""
    private var displayAssertion: IOPMAssertionID = 0
    private let controls = InputControl()
    private let localCursor = LocalCursor()
    private let trackpad = TrackpadBridge()
    private let voice = VoiceBridge()
    private let voiceTransport = VoiceTransport()
    private let clipboard = ClipboardBridge()
    @Published private(set) var clipboardReady = false
    @Published private(set) var clipboardStatus = "剪贴板共享未连接"
    private var voiceKeysReady = false
    @Published private(set) var voiceReady = false
    @Published private(set) var voiceStatus = "Mac 豆包语音：Fn 按住说话，右 Option 免按"
    private var lastVoiceError = ""
    @Published private(set) var roundTripMs = -1.0
    @Published private(set) var gesturesReady = false
    @Published private(set) var gesturesStatus = "正在连接原生多指触控"
    private let files = FileManager.default
    let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DJF Input Router")

    init(autoStart: Bool = true) {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "保持输入路由后台连接与恢复")
        running = autoStart
        for (key, isToggle) in [("toggleShortcut", true), ("emergencyShortcut", false)] {
            if let data = UserDefaults.standard.data(forKey: key),
                let value = try? JSONDecoder().decode(RouterShortcut.self, from: data), value.valid {
                if isToggle { toggleShortcut = value } else { emergencyShortcut = value }
            }
        }
        controls.setShortcuts(toggle: toggleShortcut, emergency: emergencyShortcut)
        let savedGain = UserDefaults.standard.double(forKey: "pointerGain")
        if (0.1...10).contains(savedGain) { pointerGain = (savedGain * 100).rounded() / 100 }
        controls.setPointerGain(pointerGain)
        let savedScrollGain = UserDefaults.standard.double(forKey: "scrollGain")
        if (0.1...10).contains(savedScrollGain) { scrollGain = (savedScrollGain * 100).rounded() / 100 }
        controls.setScrollGain(scrollGain)
        let savedDragTapInterval = UserDefaults.standard.double(forKey: "dragTapInterval")
        if (0.01...0.30).contains(savedDragTapInterval) { dragTapInterval = (savedDragTapInterval * 100).rounded() / 100 }
        controls.setDragTapInterval(dragTapInterval)
        clipboard.onState = { [weak self] ready, message in
            self?.clipboardReady = ready; self?.clipboardStatus = message
        }
        trackpad.onState = { [weak self] ready, message in
            guard let self else { return }
            self.gesturesReady = ready; self.gesturesStatus = message
            self.trackpad.setRouting(self.destination == .windows)
            self.controls.setNativeGestures(ready)
        }
        let inputControl = controls
        let cursor = localCursor
        controls.onRecoverCursor = { cursor.setRouting(false) }
        let touchBridge = trackpad
        trackpad.onScrollReady = { ready in inputControl.setMacScroll(ready) }
        trackpad.onDeleteReady = { ready in inputControl.setDeleteEnabled(ready) }
        controls.onDelete = { touchBridge.delete() }
        controls.onViewerScreenshot = { touchBridge.prepareLocalScreenshot() }
        controls.canUseNativeViewerShortcuts = { [weak self] in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.updateRDPPointer()
                    return self.connected && self.destination == .mac && self.rdpPointer && !self.voice.isPrepared
                }
            }
        }
        controls.onScroll = { x, y, begin in touchBridge.scroll(x: x, y: y, begin: begin) }
        voice.onActive = { [weak self] active in
            if !active, let self, self.destination == .mac, self.voice.isActive { return }
            inputControl.setVoiceCapture(active)
        }
        voice.onStatus = { [weak self] text in self?.voiceStatus = text }
        voice.onBegin = { [weak self] session in
            self?.lastVoiceError = ""; self?.voiceTransport.send(type: "begin", session: session)
        }
        voice.onUpdate = { [weak self] session, text in self?.voiceTransport.send(type: "update", session: session, text: text) }
        voice.onEnd = { [weak self] session in self?.voiceTransport.send(type: "end", session: session) }
        voice.onCancel = { [weak self] session in self?.voiceTransport.send(type: "cancel", session: session) }
        voiceTransport.onReady = { [weak self] ready in
            guard let self else { return }; self.voiceReady = ready
            inputControl.setVoiceEnabled(ready && self.voiceKeysReady)
            if !ready {
                if self.destination == .mac { self.voice.leave() }
                else { self.voice.cancel() }
            }
        }
        voiceTransport.onAcknowledged = { [weak self] count in self?.voiceStatus = "已实时输入 Windows：\(count) 字符" }
        voiceTransport.onError = { [weak self] message in
            guard let self else { return }
            self.lastVoiceError = message
            if self.destination == .mac { self.voice.leave() }
            else { self.voice.cancel() }
            self.voiceStatus = message
        }
        controls.onVoiceCancel = { [weak self] in DispatchQueue.main.async { self?.voice.cancel() } }
        // The HID tap runs on InputControl's worker. Prepare before the real
        // modifier reaches Doubao; replaying it after key-up can toggle dictation.
        let speechClient = voice
        controls.onVoicePrepare = { [weak self] key in
            let allowed = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.updateRDPPointer()
                    return self.connected && self.destination == .mac && self.voiceReady && self.rdpPointer
                }
            }
            return allowed && speechClient.prepareFromHID(trigger: key)
        }
        controls.onVoiceDiscard = { [weak self] in
            let native = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.destination == .mac }
            }
            if native { speechClient.leaveFromHID() }
        }
        controls.onVoiceEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                let native = self.destination == .mac
                if native { self.updateRDPPointer() }
                guard self.connected, self.voiceReady, !native || self.rdpPointer else {
                    inputControl.setVoiceCapture(false)
                    return
                }
                if native && !self.voice.isPrepared {
                    inputControl.setVoiceCapture(false); return
                }
                self.voice.handle(event)
            }
        }
        trackpad.onContacts = { count in inputControl.setContactCount(count) }
        trackpad.onTapReservation = { reserved in inputControl.setTapReservation(reserved) }
        trackpad.setSwitchGesture(switchGesture)
        trackpad.onDoubleTap = { [weak self] in
            guard let self, self.pendingDestination == nil else { return }
            self.select(self.destination == .mac ? .windows : .mac)
        }
        trackpad.onTouchFrame = { count, x, y, time in inputControl.setTouchFrame(count: count, x: x, y: y, time: time) }
        controls.onRequest = { [weak self] target in
            // Prepare the local speech field before Deskflow hides/freezes the cursor.
            guard let self else { return }
            self.desired = target
            if self.connected {
                if target == .windows { self.select(target) }
                else { self.expectSwitch(target) }
            }
            if !self.connected && target == .windows { self.running = true; self.nextRetry = .distantPast; self.check() }
        }
        controls.onEmergency = { [weak self] in
            guard let self else { return }
            self.recover(self.controls.recoveryReason + "，输入已返回 Mac；后台重新连接")
        }
        try? files.createDirectory(at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.djf.inputrouter.control"), object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch note.userInfo?["command"] as? String {
                    case "mac": self.select(.mac)
                    case "windows": self.select(.windows)
                    case "stop": self.stop()
                    case "emergency": self.emergency()
                    case "release-voice-cancel":
                        if let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: false) {
                            up.flags = []; MacVoiceEvents.post(up)
                        }
                    case "open-permissions": self.openPermissions()
                    case "set-shortcut":
                        if let toggle = note.userInfo?["toggle"] as? Bool,
                           let encoded = note.userInfo?["value"] as? String,
                           let data = Data(base64Encoded: encoded),
                           let shortcut = try? JSONDecoder().decode(RouterShortcut.self, from: data),
                           let error = self.setShortcut(toggle: toggle, value: shortcut) {
                            self.status = error
                        }
                    case "reconnect": self.reconnect()
                    case "open-console": self.openConsoleDesktop()
                    case "use-rdp": self.useRDPDesktop()
                    case "clear-console-password": ConsoleDesktop.clearCopiedPassword()
                    case "console-check":
                        ConsoleDesktop.checkRender { [weak self] result in
                            guard let self, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
                            try? data.write(to: self.support.appendingPathComponent("console-check.json"), options: .atomic)
                        }
                    case "lan-address":
                        if let value = note.userInfo?["value"] as? String { _ = self.setLANAddress(value) }
                    case "switch-gesture":
                        if let value = note.userInfo?["value"] as? String,
                           let gesture = TouchSwitchGesture(rawValue: value) { self.setSwitchGesture(gesture) }
                    case "modifier-pulse": if self.connected && self.destination == .windows { RouterEntry.modifierPulse() }
                    case "voice-path-check":
                        let result: [String: Any] = self.connected && self.destination == .windows && self.voiceKeysReady
                            ? runLocalVoicePathCheck() : ["pass": false, "error": "Windows routing must be active"]
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                            try? data.write(to: self.support.appendingPathComponent("voice-path-check.json"), options: .atomic)
                        }
                    case "transport":
                        if let value = note.userInfo?["value"] as? String, let transport = RouterTransport(rawValue: value) {
                            self.setTransport(transport)
                        }
                    case "pointer-gain":
                        if let value = note.userInfo?["value"] as? String, let gain = Double(value) {
                            self.setPointerGain(gain)
                        }
                    case "scroll-gain":
                        if let value = note.userInfo?["value"] as? String, let gain = Double(value) {
                            self.setScrollGain(gain)
                        }
                    case "drag-tap-interval":
                        if let value = note.userInfo?["value"] as? String, let interval = Double(value) {
                            self.setDragTapInterval(interval)
                        }
                    case "quit": self.shutdown(); DispatchQueue.main.async { NSApp.terminate(nil) }
                    default: break
                    }
                    self.writeState(request: note.userInfo?["request"] as? String ?? "")
                }
            }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateRDPPointer() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, self.running else { return }
            self.reconnect()
        } }
        DispatchQueue.main.async { [weak self] in self?.check() }
        writeState(request: "startup")
    }

    private func check() {
        defer { writeState(request: "periodic") }
        updateRDPPointer()
        localCursor.refresh()
        roundTripMs = trackpad.snapshot["roundTripMedianMs"] as? Double ?? -1
        accessibility = AXIsProcessTrusted()
        monitoring = CGPreflightListenEventAccess()
        var count: UInt32 = 0
        displayAvailable = CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
        if !accessibility {
            stopProcesses(); trackpad.stopCapture(); status = "输入仍在 Mac：系统输入权限尚未生效"; return
        }
        if !controls.isInstalled && !controls.install() {
            stopProcesses(); status = "无法建立底层输入钩子，请检查输入权限"; return
        }
        if !displayAvailable {
            stopProcesses(); status = "打开 Mac 屏幕后自动连接"; return
        }
        if IsSecureEventInputEnabled() {
            stopProcesses(); trackpad.stopCapture(); status = "Mac 正在使用安全输入，路由已暂停"; return
        }
        trackpad.startCapture()
        if !running { return }
        if let last = ipcLastReply, let ipc {
            if Date().timeIntervalSince(last) > 3 {
                recover("输入后端无响应，输入已返回 Mac；后台重新连接")
                return
            }
            sendIPC("noop", ipc)
        }
        let network = Self.activeNetworkSignature()
        let changed = networkObserved
        networkObserved = true
        if network != networkSignature {
            networkSignature = network
            if transport == .direct {
                retryCount = 0; nextRetry = .distantPast
                if changed { stopProcesses(); status = "网络已变化，正在重新查找 Windows" }
            }
        }
        if engine != nil, !connected, let deadline = clientDeadline, Date() >= deadline {
            if !receiverRepairRequested {
                repairReceiver()
                clientDeadline = Date().addingTimeInterval(8)
            } else {
                recover("Windows 键盘鼠标通道未响应，正在重新连接")
                return
            }
        }
        if usingConfiguredSSH && connected && destination == .mac && lookup == nil && directProbes.isEmpty &&
            Date() >= nextRetry {
            nextRetry = Date().addingTimeInterval(30)
            verifyDirect(ip: "djf.local", refreshOnFailure: false, recoveringDirect: true)
        }
        if engine == nil && lookup == nil && directProbes.isEmpty && Date() >= nextRetry {
            retryCount += 1
            let delay = retryCount <= 20 ? 2.0 : min(60.0, 2.0 + Double(retryCount - 20) * 2.0)
            nextRetry = Date().addingTimeInterval(delay)
            status = "正在查找 RTX 5060 Ti 实体主机"
            discover()
        }
    }

    private func discover() {
        connectionStarted = Date()
        if transport == .bluetooth { address = bluetoothAddress; launch(ip: "DJF-Windows") }
        else { verifyDirect(ip: "djf.local", refreshOnFailure: true) }
    }

    // Registry requests carry metadata only; input uses the selected SSH path.
    private func lookupAddress(failedAddress: String? = nil) {
        guard networkSignature.contains("=10.21.") else { waitForDirect(); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "bupt208",
            "/home/djf/.local/bin/djf-windows-ip --json"]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        lookup = process
        process.terminationHandler = { [weak self] process in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self, self.lookup === process else { return }
                self.lookup = nil
                guard self.running else { return }
                guard process.terminationStatus == 0,
                    let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    report["status"] as? String == "online",
                    report["name"] as? String == "DJF-Windows",
                    (report["gpu"] as? String)?.contains("5060 Ti") == true,
                    let ip = report["source_ip"] as? String,
                    Self.validIPv4(ip) else {
                    self.verifyConfiguredSSH(); return
                }
                self.cachedAddress = ip
                UserDefaults.standard.set(ip, forKey: "windowsAddress")
                if ip == failedAddress { self.verifyConfiguredSSH() }
                else { self.verifyDirect(ip: ip, refreshOnFailure: false) }
            }
        }
        do { try process.run() }
        catch { lookup = nil; waitForDirect() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if self?.lookup === process && process.isRunning { process.terminate() }
        }
    }

    private func sshArguments(configuredRoute: Bool = false) -> [String] {
        let known = Bundle.main.url(forResource: "known-hosts", withExtension: nil)!
        var args = ["-T", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-i", files.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/mywin_ed25519").path,
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=DJF-Windows",
            "-o", "UserKnownHostsFile=\"" + known.path + "\"", "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=\(configuredRoute || transport == .bluetooth ? 8 : 2)", "-o", "ConnectionAttempts=1"]
        if !configuredRoute {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BluetoothPipe").path
            let proxy = transport == .direct ? "none" : "exec '" + helper.replacingOccurrences(of: "'", with: "'\\''") + "' " + bluetoothAddress + " 29"
            args += ["-o", "ProxyCommand=" + proxy, "-o", "ProxyJump=none"]
        }
        return args
    }

    private func verifyConfiguredSSH() {
        guard running, transport == .direct, networkSignature.contains("=10.21.") else { waitForDirect(); return }
        status = "直连受阻，正在尝试 SSH 跳板"
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(configuredRoute: true) + ["djf@DJF-Windows", "hostname"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        lookup = process
        process.terminationHandler = { [weak self] process in
            let host = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self, self.lookup === process else { return }
                self.lookup = nil
                guard self.running else { return }
                if process.terminationStatus == 0 && host.uppercased() == "DJF" {
                    self.usingConfiguredSSH = true
                    self.address = self.cachedAddress
                    self.nextRetry = Date().addingTimeInterval(30)
                    self.launch(ip: "DJF-Windows")
                } else { self.waitForDirect() }
            }
        }
        do { try process.run() }
        catch { lookup = nil; waitForDirect() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.lookup === process else { return }
            self.lookup = nil
            if process.isRunning { process.terminate() }
            self.waitForDirect()
        }
    }

    private func verifyDirect(ip: String, refreshOnFailure: Bool, recoveringDirect: Bool = false) {
        guard running, ip == "djf.local" || Self.validIPv4(ip) else { return }
        if !recoveringDirect { status = "正在直连 DJF-Windows" }
        cancelDirectProbes()
        let generation = probeGeneration
        var candidates: [String] = []
        for candidate in (ip == "djf.local" ? [lanAddress, cachedAddress, ip] : [ip]) {
            if (candidate == "djf.local" || Self.validIPv4(candidate)) && !candidates.contains(candidate) { candidates.append(candidate) }
        }
        // Race known addresses and mDNS: one dead resolver must not delay a live IP.
        var remaining = candidates.count
        func failed() {
            remaining -= 1
            guard remaining == 0 else { return }
            if recoveringDirect { return }
            if refreshOnFailure { lookupAddress(failedAddress: cachedAddress) }
            else { verifyConfiguredSSH() }
        }
        for candidate in candidates {
            let process = Process(), out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments() + ["djf@" + candidate, "hostname"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out; process.standardError = FileHandle.nullDevice
            directProbes.append(process)
            process.terminationHandler = { [weak self] process in
                let host = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard let self, self.probeGeneration == generation, self.running,
                          self.directProbes.contains(where: { $0 === process }) else { return }
                    self.directProbes.removeAll { $0 === process }
                    if process.terminationStatus == 0 && host.uppercased() == "DJF" {
                        self.cancelDirectProbes()
                        if recoveringDirect { self.stopProcesses() }
                        self.usingConfiguredSSH = false; self.address = candidate; self.launch(ip: candidate)
                    } else { failed() }
                }
            }
            do { try process.run() }
            catch { directProbes.removeAll { $0 === process }; failed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.probeGeneration == generation,
                      self.directProbes.contains(where: { $0 === process }) else { return }
                self.directProbes.removeAll { $0 === process }
                if process.isRunning { process.terminate() }
                failed()
            }
        }
    }

    private func waitForDirect() {
        guard running else { return }
        status = "局域网暂不可达，输入保留在 Mac；正在持续重试"
        usingConfiguredSSH = false
    }

    private func cancelDirectProbes() {
        probeGeneration += 1
        for process in directProbes where process.isRunning { process.terminate() }
        directProbes.removeAll()
    }

    private static func activeNetworkSignature() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "" }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            if let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
               item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer,
                               socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: item.pointee.ifa_name) + "=" + String(cString: buffer))
                }
            }
            cursor = item.pointee.ifa_next
        }
        return addresses.sorted().joined(separator: ";")
    }

    static func validIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private func launch(ip: String) {
        guard engine == nil, running else { return }
        do {
            let runtime = support.appendingPathComponent("Runtime")
            try files.createDirectory(at: runtime, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let config = support.appendingPathComponent("server.conf")
            try """
            section: links
            end
            section: options
                keystroke(F18) = switchToScreen(DJF-Windows)
                keystroke(F19) = switchToScreen(DJF-Mac)
                keystroke(\(emergencyShortcut.deskflow)) = switchToScreen(DJF-Mac)
            end
            """.write(to: config, atomically: true, encoding: .utf8)
            let settings = support.appendingPathComponent("server.ini")
            try """
            [core]
            computerName=DJF-Mac
            coreMode=2
            processMode=0
            interface=127.0.0.1
            port=24800
            [computer_DJF-Mac]
            name=DJF-Mac
            [computer_DJF-Windows]
            name=DJF-Windows
            modifierSuper=ctrl
            modifierCtrl=super
            [server]
            externalConfig=true
            externalConfigFile=\(config.path)
            enableClipboard=false
            [security]
            tlsEnabled=false
            [log]
            level=INFO
            toFile=false
            """.write(to: settings, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/DJFDeskflow")
            // This controller owns exactly one backend; Qt's global shared-memory
            // lock can survive a forced exit and must not prevent its replacement.
            process.arguments = ["server", "--new-instance", "--settings", settings.path]
            var env = ProcessInfo.processInfo.environment
            env["TMPDIR"] = runtime.path + "/"
            env["DYLD_INSERT_LIBRARIES"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VoicePassthrough.dylib").path
            env["QT_PLUGIN_PATH"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Deskflow.app/Contents/PlugIns").path
            process.environment = env
            let backendLogURL = support.appendingPathComponent("backend.log")
            if !files.fileExists(atPath: backendLogURL.path) {
                files.createFile(atPath: backendLogURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            }
            backendLog = try FileHandle(forWritingTo: backendLogURL)
            if (try backendLog?.seekToEnd() ?? 0) > 2_000_000 { try backendLog?.truncate(atOffset: 0) }
            try backendLog?.write(contentsOf: Data("\n--- backend start \(Date()) ---\n".utf8))
            let out = Pipe(); process.standardOutput = out; process.standardError = out
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self, self.engine === process else { return }
                    self.readEngine(text)
                }
            }
            engine = process
            clientDeadline = Date().addingTimeInterval(8)
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.engine === process else { return }
                    self.recover("转发后端已退出（\(process.terminationStatus)），输入已返回 Mac；后台重新连接")
                }
            }
            try process.run()
            _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "DJF 输入路由保持连接" as CFString, &displayAssertion)
            controls.reset()
            controls.configure(available: false, pid: process.processIdentifier)
            status = "正在建立安全连接 · " + connectionRoute
            connectIPC(path: runtime.appendingPathComponent("deskflow-core").path, attempt: 0)
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = sshArguments(configuredRoute: usingConfiguredSSH) + ["-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=1", "-o", "ServerAliveCountMax=2",
                "-N", "-R", "127.0.0.1:24800:127.0.0.1:24800",
                "-L", "127.0.0.1:24801:127.0.0.1:24801",
                "-L", "127.0.0.1:24803:127.0.0.1:24803",
                "-L", "127.0.0.1:24804:127.0.0.1:24804", "djf@" + ip]
            let errorLog = support.appendingPathComponent("ssh-error.log")
            files.createFile(atPath: errorLog.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            ssh.standardOutput = FileHandle.nullDevice
            ssh.standardError = try FileHandle(forWritingTo: errorLog)
            tunnel = ssh
            ssh.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.tunnel === process else { return }
                    self.recover("连接中断，输入已返回 Mac；后台重新连接")
                }
            }
            try ssh.run()
            trackpad.start(tokenURL: support.appendingPathComponent("trackpad-token"))
            clipboard.start(tokenURL: support.appendingPathComponent("trackpad-token"))
            voiceTransport.start(tokenURL: support.appendingPathComponent("trackpad-token"))
            let guardProcess = Process()
            guardProcess.executableURL = Bundle.main.executableURL
            guardProcess.arguments = ["--guard-parent", String(getpid()), String(process.processIdentifier), String(ssh.processIdentifier)]
            guardProcess.standardOutput = FileHandle.nullDevice
            guardProcess.standardError = FileHandle.nullDevice
            guardian = guardProcess
            try guardProcess.run()
        } catch { stopProcesses(); status = "无法启动：\(error.localizedDescription)" }
    }

    private func connectIPC(path: String, attempt: Int) {
        guard engine?.isRunning == true else { return }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        ipc = connection; ipcBuffer = Data()
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.ipc === connection else { return }
                switch state {
                case .ready:
                    self.ipcLastReply = Date()
                    self.sendIPC("hello=DJF-Input-Router", connection)
                    self.receiveIPC(connection)
                case .failed, .waiting:
                    connection.cancel()
                    if attempt < 15 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if self.ipc === connection { self.connectIPC(path: path, attempt: attempt + 1) }
                        }
                    } else { self.stopProcesses(); self.status = "转发后端未就绪，输入保留在 Mac" }
                default: break
                }
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func sendIPC(_ value: String, _ connection: NWConnection) {
        connection.send(content: (value + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func receiveIPC(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                guard let self, self.ipc === connection else { return }
                if let data { self.ipcBuffer.append(data) }
                while let end = self.ipcBuffer.firstIndex(of: 10) {
                    let line = String(decoding: self.ipcBuffer[..<end], as: UTF8.self)
                    self.ipcBuffer.removeSubrange(...end)
                    self.ipcLastReply = Date()
                    if line.hasPrefix("versionMismatch=") {
                        self.sendIPC("hello=" + line.dropFirst(16), connection)
                    } else if line == "connectionState=Connected" {
                        self.connectionMilliseconds = Date().timeIntervalSince(self.connectionStarted) * 1000
                        self.clientDeadline = nil
                        self.pendingDestination = nil
                        self.retryCount = 0
                        self.connected = true; self.status = "DJF-Windows 已连接 · " + self.connectionRoute
                        self.armControls()
                        if self.desired == .windows { self.select(.windows) }
                        self.writeState(request: "connected")
                    } else if line == "connectionState=Listening" {
                        if self.clientDeadline == nil { self.clientDeadline = Date().addingTimeInterval(8) }
                        self.localCursor.setRouting(false)
                        self.voice.leave()
                        self.connected = false; self.destination = .mac; self.pendingDestination = nil
                        self.controls.reset(); self.trackpad.setRouting(false)
                        self.status = "等待 Windows 输入服务连接"
                        self.armControls()
                        self.writeState(request: "disconnected")
                    }
                }
                if done || error != nil { self.stopProcesses(); self.status = "后端连接已断开，输入已回到 Mac" }
                else { self.receiveIPC(connection) }
            }
        }
    }

    private func armControls() {
        controls.configure(available: connected, pid: engine?.processIdentifier ?? 0)
        controls.confirm(destination)
        // Head insertion now places this control tap before Deskflow's tap.
        if !controls.install() { stopProcesses(); status = "无法拦截切换键，请检查输入权限" }
    }

    private func readEngine(_ text: String) {
        try? backendLog?.write(contentsOf: Data(text.utf8))
        logBuffer += text
        while let end = logBuffer.firstIndex(of: "\n") {
            let line = String(logBuffer[..<end])
            logBuffer.removeSubrange(...end)
            if line.contains("DJF local voice passthrough loaded") {
                voiceKeysReady = true; controls.setVoiceEnabled(voiceReady)
            }
            if line.contains("switch from \"DJF-Mac\" to \"DJF-Windows\"") { didSwitch(.windows) }
            if line.contains("switch from \"DJF-Windows\" to \"DJF-Mac\"") { didSwitch(.mac) }
            if line.contains("FATAL") || line.contains("failed to create quartz event tap") || line.contains("failed to register hotkey") {
                stopProcesses(); status = "转发后端无法捕获输入，请授权后重试"
            }
        }
    }

    func select(_ target: InputDestination) {
        if destination == .mac && voice.isPrepared { voice.leave() }
        desired = target
        if connected && target == .windows && destination != .windows {
            activateRDPWindow()
            _ = voice.prepare()
        }
        if connected && destination != target { expectSwitch(target); controls.select(target) }
        else if connected { pendingDestination = nil; return }
        else if target == .mac { desired = .mac; pendingDestination = nil }
        else { running = true; nextRetry = .distantPast; check() }
    }

    private func expectSwitch(_ target: InputDestination) {
        guard destination != target else { pendingDestination = nil; return }
        pendingDestination = target
        status = target == .windows ? "正在将输入切换到 DJF-Windows…" : "正在将输入切回 Mac…"
        writeState(request: "switching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pendingDestination == target, self.destination != target else { return }
            self.recover("切换未收到确认，输入已返回 Mac；后台重新连接")
        }
    }

    private func didSwitch(_ target: InputDestination) {
        destination = target; controls.confirm(target)
        if target == .mac { rdpPointer = false; controls.setRDPPointer(false) }
        trackpad.setRouting(target == .windows)
        localCursor.setRouting(target == .windows && !rdpPointer)
        if pendingDestination == target { pendingDestination = nil }
        status = target == .windows ? "键盘与触控板正在控制 DJF-Windows" : "键盘与触控板已回到 Mac"
        writeState(request: "switch-confirmed")
        if target == .mac { voice.leave(restoreSource: false) }
        if target == .mac, let previousRDPApp {
            self.previousRDPApp = nil
            if RemoteDesktopMode.isViewer(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") {
                previousRDPApp.activate(options: [])
            }
        }
        if target == .windows { updateRDPPointer() }
        localCursor.setRouting(target == .windows && !rdpPointer)
        writeState(request: "switched")
    }

    func setShortcut(toggle: Bool, value: RouterShortcut) -> String? {
        guard value.valid else { return "字母和普通按键至少需要一个修饰键；也可以使用 F 功能键。" }
        guard value != (toggle ? emergencyShortcut : toggleShortcut) else { return "切换键和紧急返回键不能相同。" }
        stop()
        if toggle { toggleShortcut = value } else { emergencyShortcut = value }
        UserDefaults.standard.set(try! JSONEncoder().encode(value), forKey: toggle ? "toggleShortcut" : "emergencyShortcut")
        controls.setShortcuts(toggle: toggleShortcut, emergency: emergencyShortcut)
        reconnect()
        return nil
    }

    func setSwitchGesture(_ value: TouchSwitchGesture) {
        guard switchGesture != value else { return }
        trackpad.setSwitchGesture(value)
        switchGesture = value
        UserDefaults.standard.set(value.rawValue, forKey: "switchGesture")
        writeState(request: "gesture")
    }

    func reconnect() { stopProcesses(); running = true; desired = .mac; retryCount = 0; nextRetry = .distantPast; check() }

    func openConsoleDesktop() {
        guard !openingConsole else { return }
        guard destination == .mac else {
            consoleStatus = "请先将输入切回 Mac。"; return
        }
        openingConsole = true; consoleStatus = "正在连接共享实体桌面…"
        ConsoleDesktop.checkConnection { [weak self] ready in
            guard let self, self.openingConsole else { return }
            if ready { self.transferConsoleDesktop() }
            else {
                self.openingConsole = false
                self.consoleStatus = "共享画面隧道尚未就绪；请稍后重新连接。"
            }
        }
    }

    private func transferConsoleDesktop() {
        let process = Process(), out = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let configured = usingConfiguredSSH || address.isEmpty
        let host = configured || transport == .bluetooth ? "DJF-Windows" : address
        process.arguments = sshArguments(configuredRoute: configured) + ["djf@" + host, ConsoleDesktop.command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = error
        consoleRequest = process
        process.terminationHandler = { [weak self] process in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let failure = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.consoleRequest === process else { return }
                self.consoleRequest = nil; self.openingConsole = false
                guard process.terminationStatus == 0,
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      result["host"] as? String == "DJF",
                      let session = result["sessionId"] as? Int,
                      result["consoleId"] as? Int == session else {
                    self.consoleStatus = "共享实体桌面连接失败：" + (failure.isEmpty ? "未收到主机确认。" : failure.trimmingCharacters(in: .whitespacesAndNewlines))
                    return
                }
                self.desktopMode = .console
                UserDefaults.standard.set(self.desktopMode.rawValue, forKey: "desktopMode")
                self.consoleStatus = "实体控制台已就绪，正在连接共享画面…"
                self.updateRDPPointer()
                ConsoleDesktop.openViewer { [weak self] in self?.consoleStatus = $0 }
                self.writeState(request: "console-opened")
            }
        }
        do { try process.run() }
        catch {
            consoleRequest = nil; openingConsole = false
            consoleStatus = "共享实体桌面连接失败：" + error.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.consoleRequest === process && process.isRunning { process.terminate() }
        }
    }

    func useRDPDesktop() {
        guard destination == .mac else { consoleStatus = "请先将输入切回 Mac。"; return }
        if consoleRequest?.isRunning == true { consoleRequest?.terminate() }
        consoleRequest = nil; openingConsole = false
        desktopMode = .rdp
        UserDefaults.standard.set(desktopMode.rawValue, forKey: "desktopMode")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: desktopMode.bundleIdentifier).first {
            app.activate(options: [])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopMode.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        consoleStatus = "Windows App 使用独立 RDP 会话；机箱 USB 键盘请使用共享实体桌面。"
    }

    private func recover(_ reason: String) {
        let resume = running
        // A frozen backend cannot process SIGTERM; release its port before
        // launching a replacement, rather than racing the delayed cleanup.
        if let engine, engine.isRunning { kill(engine.processIdentifier, SIGKILL) }
        stopProcesses(); desired = .mac
        status = reason
        nextRetry = .distantPast
        writeState(request: "recovery")
        if resume { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.check() } }
    }
    private func repairReceiver() {
        receiverRepairRequested = true
        status = "正在恢复 Windows 输入接收服务"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let host = usingConfiguredSSH || transport == .bluetooth ? "DJF-Windows" : address
        process.arguments = sshArguments(configuredRoute: usingConfiguredSSH) + ["djf@" + host,
            "schtasks.exe /Run /TN DJF-Windows-Input-Session"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        receiverRepair = process
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.receiverRepair === process else { return }
                self.receiverRepair = nil
                if process.terminationStatus != 0 { self.status = "Windows 服务恢复请求失败，继续自动重连" }
            }
        }
        do { try process.run() } catch { receiverRepair = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.receiverRepair === process && process.isRunning { process.terminate() }
        }
    }
    @discardableResult
    func setLANAddress(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || Self.validIPv4(value) else { return false }
        guard lanAddress != value else { return true }
        lanAddress = value
        UserDefaults.standard.set(value, forKey: "lanAddress")
        if running && transport == .direct { reconnect() }
        return true
    }
    func setTransport(_ value: RouterTransport) {
        guard transport != value else { return }
        stopProcesses(); transport = value; address = ""
        UserDefaults.standard.set(value.rawValue, forKey: "transport")
        reconnect()
    }
    func emergency() { controls.emergency() }

    func stop() {
        running = false; desired = .mac
        stopProcesses()
        status = "路由已暂停，输入在 Mac"
    }

    private func stopProcesses() {
        cancelDirectProbes()
        localCursor.setRouting(false)
        voice.leave(); voiceTransport.stop(); voiceReady = false; voiceKeysReady = false
        clipboard.stop()
        let hadEngine = engine != nil
        controls.reset()
        trackpad.stop(); gesturesReady = false; gesturesStatus = "Windows 原生触控通道未连接"
        roundTripMs = -1; controls.setNativeGestures(false)
        ipc?.cancel(); ipc = nil; ipcLastReply = nil
        for process in [guardian, lookup, engine, tunnel, receiverRepair].compactMap({ $0 }) {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        guardian = nil; lookup = nil; engine = nil; tunnel = nil; logBuffer = ""
        receiverRepair = nil; receiverRepairRequested = false
        clientDeadline = nil
        try? backendLog?.close(); backendLog = nil
        connected = false; destination = .mac; pendingDestination = nil; usingConfiguredSSH = false
        if hadEngine {
            if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func shutdown() {
        stop(); trackpad.stopCapture(); controls.remove(); timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private func updateRDPPointer() {
        var enabled = false
        rdpFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        // Explicit speech temporarily activates our IME client without changing
        // the routing destination or the Windows text target.
        if destination == .mac && voice.isTransient,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return }
        rdpWindowTitle = ""
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            rdpWindowTitle = NSApp.keyWindow?.title ?? ""
            enabled = RemoteDesktopMode.nativePointer(bundle: "com.djf.inputrouter", title: rdpWindowTitle, destination: destination)
        } else if let app = NSWorkspace.shared.frontmostApplication, RemoteDesktopMode.isViewer(app.bundleIdentifier ?? "") {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.2)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var title: CFTypeRef?
                let focused = unsafeBitCast(window, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(focused, 0.2)
                _ = AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &title)
                rdpWindowTitle = title as? String ?? ""
                // Screen Sharing uses native input while unrouted. Once explicitly
                // routed, Deskflow owns its pointer so Mac fullscreen edges stay idle.
                enabled = RemoteDesktopMode.nativePointer(bundle: app.bundleIdentifier ?? "", title: rdpWindowTitle, destination: destination)
            }
        }
        if destination == .mac && !RemoteDesktopMode.isViewer(rdpFrontmost),
           let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            previousRDPApp = app
        }
        if enabled != rdpPointer {
            rdpPointer = enabled; controls.setRDPPointer(enabled)
            localCursor.setRouting(destination == .windows && !enabled)
        }
        if destination == .mac && desired == .mac && !enabled && voice.isPrepared { voice.leave() }
    }

    private func activateRDPWindow() {
        if desktopMode == .console {
            if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != getpid() {
                previousRDPApp = current
            }
            ConsoleDesktop.activateViewer()
            updateRDPPointer()
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: desktopMode.bundleIdentifier).first else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        rdpActivation = "windows=\(result.rawValue)"
        var windows = value as? [AXUIElement] ?? []
        if windows.isEmpty {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                windows = [unsafeBitCast(focused, to: AXUIElement.self)]
            }
        }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 1)
            var title: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard RemoteDesktopMode.matches(bundle: desktopMode.bundleIdentifier, title: title as? String ?? "") else { continue }
            if let current = NSWorkspace.shared.frontmostApplication,
               current.processIdentifier != app.processIdentifier && current.processIdentifier != getpid() {
                previousRDPApp = current
            }
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            rdpActivation = "DJF-Windows raise=\(raised.rawValue) activated=\(activated)"
            updateRDPPointer()
            return
        }
    }

    @discardableResult
    func setPointerGain(_ value: Double) -> Bool {
        guard value.isFinite && (0.1...10).contains(value) else { return false }
        let value = (value * 100).rounded() / 100
        controls.setPointerGain(value)
        pointerGain = value
        UserDefaults.standard.set(value, forKey: "pointerGain")
        return true
    }
    @discardableResult
    func setScrollGain(_ value: Double) -> Bool {
        guard value.isFinite && (0.1...10).contains(value) else { return false }
        scrollGain = (value * 100).rounded() / 100
        controls.setScrollGain(scrollGain)
        UserDefaults.standard.set(scrollGain, forKey: "scrollGain")
        return true
    }

    @discardableResult
    func setDragTapInterval(_ value: Double) -> Bool {
        guard value.isFinite && (0.01...0.30).contains(value) else { return false }
        dragTapInterval = (value * 100).rounded() / 100
        controls.setDragTapInterval(dragTapInterval)
        UserDefaults.standard.set(dragTapInterval, forKey: "dragTapInterval")
        return true
    }

    private func writeState(request: String) {
        let snapshot: [String: Any] = ["request": request, "pid": getpid(),
            "destination": destination.rawValue, "connected": connected, "status": status,
            "running": running, "updatedAt": Date().timeIntervalSince1970,
            "connectionMilliseconds": connectionMilliseconds,
            "toggleShortcutValue": ["keyCode": toggleShortcut.keyCode, "modifiers": toggleShortcut.modifiers],
            "emergencyShortcutValue": ["keyCode": emergencyShortcut.keyCode, "modifiers": emergencyShortcut.modifiers],
            "address": address, "lanAddress": lanAddress, "transport": transport.rawValue, "connectionRoute": connectionRoute, "usingConfiguredSSH": usingConfiguredSSH, "accessibility": accessibility, "inputMonitoring": monitoring,
            "desktopMode": desktopMode.rawValue, "consoleStatus": consoleStatus, "openingConsole": openingConsole,
            "activeDisplay": displayAvailable, "corePID": engine?.processIdentifier ?? 0,
            "localCursorHidden": localCursor.hidden, "localCursorVisible": DJFCursorIsVisible() != 0,
            "rdpPointer": rdpPointer, "rdpFrontmost": rdpFrontmost, "rdpWindowTitle": rdpWindowTitle, "rdpActivation": rdpActivation,
            "lastRecovery": controls.recoveryReason,
            "voiceInput": voice.snapshot,
            "nativeRDPVoice": destination == .mac && voice.isPrepared,
            "lastVoiceError": lastVoiceError,
            "clipboardReady": clipboardReady, "clipboardStatus": clipboardStatus,
            "tunnelPID": tunnel?.processIdentifier ?? 0, "guardianPID": guardian?.processIdentifier ?? 0,
            "toggleShortcut": toggleShortcut.title, "emergencyShortcut": emergencyShortcut.title,
            "pointerGain": pointerGain, "scrollGain": scrollGain, "dragTapInterval": dragTapInterval, "switchGesture": switchGesture.rawValue,
            "voiceReady": voiceReady, "voiceKeysReady": voiceKeysReady, "voiceStatus": voiceStatus, "gesturesStatus": gesturesStatus, "nativeTrackpad": trackpad.snapshot,
            "routedMotion": controls.motionSnapshot,
            "pendingDestination": pendingDestination?.rawValue ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
            try? data.write(to: support.appendingPathComponent("status.json"), options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(.init("com.djf.inputrouter.state"), object: nil, deliverImmediately: true)
        }
        let summary = "\(running) \(connected) \(destination.rawValue) \(status)"
        if summary != lastStateSummary {
            lastStateSummary = summary
            let url = support.appendingPathComponent("recovery.log")
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            if let file = try? FileHandle(forWritingTo: url) {
                defer { try? file.close() }
                if (try? file.seekToEnd()) ?? 0 > 1_000_000 { try? file.truncate(atOffset: 0) }
                try? file.write(contentsOf: Data("\(Date()) \(summary)\n".utf8))
            }
        }
    }

    func openPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
