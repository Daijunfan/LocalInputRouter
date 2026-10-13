import AppKit
import ApplicationServices
import Carbon
import Combine
import Network
import IOKit.pwr_mgt
import Security
import Darwin

enum RouterTransport: String, CaseIterable {
    case direct, bluetooth
    var title: String { self == .direct ? "局域网 Wi-Fi" : "蓝牙直连" }
    var detail: String {
        self == .direct ? "直连已配对 Windows 的局域网 IP。" : "蓝牙承载相同的 SSH 认证；Mac 可继续使用 Wi-Fi 上网。"
    }
}

@MainActor
final class RouterController: ObservableObject {
    @Published var destination = InputDestination.mac
    @Published var connected = false
    @Published var status = "请先配置并配对 Windows 设备"
    @Published var address = ""
    @Published private(set) var transport = RouterTransport(rawValue: UserDefaults.standard.string(forKey: "transport") ?? "direct") ?? .direct
    @Published private(set) var peerAddress = UserDefaults.standard.string(forKey: "peerAddress") ?? ""
    @Published private(set) var peerHost = UserDefaults.standard.string(forKey: "peerHost") ?? ""
    @Published private(set) var peerUser = UserDefaults.standard.string(forKey: "peerUser") ?? ""
    @Published private(set) var bluetoothAddress = UserDefaults.standard.string(forKey: "bluetoothAddress") ?? ""
    @Published private(set) var bluetoothChannel = UserDefaults.standard.integer(forKey: "bluetoothChannel") == 0 ? 28 : UserDefaults.standard.integer(forKey: "bluetoothChannel")
    @Published private(set) var hostFingerprint = ""
    private var pendingHostKey: String?
    var publicKey: String { (try? String(contentsOf: support.appendingPathComponent("Keys/device_ed25519.pub"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
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
    private var engine: Process?
    private var tunnel: Process?
    private var lookup: Process?
    private var guardian: Process?
    private var ipc: NWConnection?
    private var ipcBuffer = Data()
    private var logBuffer = ""
    private var desired = InputDestination.mac
    private var nextRetry = Date.distantPast
    private var retryCount = 0
    private var networkSignature = ""
    private var networkObserved = false
    private var localPeerName: String { peerHost.contains(".") ? peerHost : peerHost + ".local" }
    @Published private(set) var usingConfiguredSSH = false
    var connectionRoute: String { transport == .direct ? "局域网直连" : transport.title }
    private var timer: Timer?
    private var commandObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var rdpPointer = false
    private var rdpFrontmost = ""
    private var rdpWindowTitle = ""
    private var previousRDPApp: NSRunningApplication?
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
    @Published private(set) var roundTripMs = -1.0
    @Published private(set) var gesturesReady = false
    @Published private(set) var gesturesStatus = "正在连接原生多指触控"
    private let files = FileManager.default
    let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalInputRouter")

    init(autoStart: Bool = true) {
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
        clipboard.onState = { [weak self] ready, message in
            self?.clipboardReady = ready; self?.clipboardStatus = message
        }
        trackpad.onState = { [weak self] ready, message in
            guard let self else { return }
            self.gesturesReady = ready; self.gesturesStatus = message
            self.controls.setNativeGestures(ready)
        }
        let inputControl = controls
        let cursor = localCursor
        controls.onRecoverCursor = { cursor.setRouting(false) }
        let touchBridge = trackpad
        trackpad.onScrollReady = { ready in inputControl.setMacScroll(ready) }
        controls.onScroll = { x, y, begin in touchBridge.scroll(x: x, y: y, begin: begin) }
        voice.onActive = { active in inputControl.setVoiceCapture(active) }
        voice.onStatus = { [weak self] text in self?.voiceStatus = text }
        voice.onBegin = { [weak self] session in self?.voiceTransport.send(type: "begin", session: session) }
        voice.onUpdate = { [weak self] session, text in self?.voiceTransport.send(type: "update", session: session, text: text) }
        voice.onEnd = { [weak self] session in self?.voiceTransport.send(type: "end", session: session) }
        voice.onCancel = { [weak self] session in self?.voiceTransport.send(type: "cancel", session: session) }
        voiceTransport.onReady = { [weak self] ready in
            guard let self else { return }; self.voiceReady = ready
            inputControl.setVoiceEnabled(ready && self.voiceKeysReady)
            if !ready { self.voice.cancel() }
        }
        voiceTransport.onAcknowledged = { [weak self] count in self?.voiceStatus = "已实时输入 Windows：\(count) 字符" }
        voiceTransport.onError = { [weak self] message in self?.voice.cancel(); self?.voiceStatus = message }
        controls.onVoiceCancel = { [weak self] in DispatchQueue.main.async { self?.voice.cancel() } }
        controls.onVoiceEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.connected, self.destination == .windows, self.voiceReady else { inputControl.setVoiceCapture(false); return }
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
            self.stop(); self.status = self.controls.recoveryReason + "，已返回 Mac；按切换键可重新连接"
        }
        try? files.createDirectory(at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let keys = support.appendingPathComponent("Keys")
        try? files.createDirectory(at: keys, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let identity = keys.appendingPathComponent("device_ed25519")
        if !files.fileExists(atPath: identity.path) {
            let generate = Process()
            generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", identity.path]
            generate.standardOutput = FileHandle.nullDevice
            generate.standardError = FileHandle.nullDevice
            do { try generate.run(); generate.waitUntilExit() }
            catch { status = "无法生成本机配对密钥：\(error.localizedDescription)" }
        }
        let token = support.appendingPathComponent("trackpad-token")
        if !files.fileExists(atPath: token.path) {
            var bytes = [UInt8](repeating: 0, count: 32)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
                let value = bytes.map { String(format: "%02x", $0) }.joined()
                try? value.write(to: token, atomically: true, encoding: .utf8)
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("org.localinputrouter.app.control"), object: nil, queue: .main) { [weak self] note in
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
                    case "quit": self.shutdown(); DispatchQueue.main.async { NSApp.terminate(nil) }
                    default: break
                    }
                    self.writeState(request: note.userInfo?["request"] as? String ?? "")
                }
            }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateRDPPointer() } }
        check()
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
        if peerHost.isEmpty || peerUser.isEmpty || !files.fileExists(atPath: support.appendingPathComponent("Keys/known_hosts").path) {
            status = "请先配置 Windows 并核对 SSH 指纹"; return
        }
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
        if engine == nil && lookup == nil && Date() >= nextRetry {
            nextRetry = Date().addingTimeInterval(2)
            status = "正在连接 \(peerHost)"
            discover()
        }
    }

    private func discover() {
        guard files.fileExists(atPath: support.appendingPathComponent("Keys/known_hosts").path),
              !peerHost.isEmpty, !peerUser.isEmpty else {
            status = "请先配置 Windows，并核对、信任 SSH 主机指纹"; return
        }
        if transport == .bluetooth {
            guard !bluetoothAddress.isEmpty else { status = "请填写已配对 Windows 的蓝牙地址"; return }
            address = bluetoothAddress; prepareReceivers(ip: "127.0.0.1")
        } else { verifyDirect(ip: localPeerName, refreshOnFailure: true) }
    }
    private func sshArguments() -> [String] {
        let known = support.appendingPathComponent("Keys/known_hosts")
        var args = ["-T", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-i", support.appendingPathComponent("Keys/device_ed25519").path,
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=LocalInputRouterPeer",
            "-o", "UserKnownHostsFile=\"" + known.path + "\"", "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=\(transport == .bluetooth ? 10 : 5)", "-o", "ConnectionAttempts=1"]
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BluetoothPipe").path
        let proxy = transport == .direct ? "none" : "exec '" + helper.replacingOccurrences(of: "'", with: "'\\''") + "' " + bluetoothAddress + " \(bluetoothChannel)"
        args += ["-o", "ProxyCommand=" + proxy, "-o", "ProxyJump=none"]
        return args
    }

    private func verifyDirect(ip: String, refreshOnFailure: Bool, recoveringDirect: Bool = false) {
        guard running, ip == localPeerName || Self.validIPv4(ip) else { return }
        if !recoveringDirect { status = "正在直连 \(peerHost)" }
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments() + [peerUser + "@" + ip, "hostname"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        lookup = process
        process.terminationHandler = { [weak self] process in
            let host = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self, self.lookup === process else { return }
                self.lookup = nil
                guard self.running else { return }
                if process.terminationStatus == 0 && host.caseInsensitiveCompare(self.peerHost) == .orderedSame {
                    if recoveringDirect { self.stopProcesses() }
                    self.usingConfiguredSSH = false; self.address = ip; self.prepareReceivers(ip: ip)
                } else if recoveringDirect {
                    return // Keep the working tunnel and input state during recovery probes.
                } else if refreshOnFailure {
                    if Self.validIPv4(self.peerAddress) { self.verifyDirect(ip: self.peerAddress, refreshOnFailure: false) }
                    else { self.waitForDirect() }
                } else { self.waitForDirect() }
            }
        }
        do { try process.run() }
        catch { lookup = nil; if !recoveringDirect { waitForDirect() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.lookup === process && process.isRunning { process.terminate() }
        }
    }

    private func waitForDirect() {
        guard running else { return }
        retryCount += 1
        let delay = retryCount <= 20 ? 2.0 : min(60.0, 2.0 + Double(retryCount - 20) * 2.0)
        status = "局域网暂不可达，输入保留在 Mac；约 \(Int(delay)) 秒后重试"
        usingConfiguredSSH = false
        nextRetry = Date().addingTimeInterval(delay)
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

    func configurePeer(address: String, user: String, host: String, bluetooth: String, channel: Int) -> Bool {
        guard Self.validIPv4(address), !user.trimmingCharacters(in: .whitespaces).isEmpty,
              !host.trimmingCharacters(in: .whitespaces).isEmpty, (1...30).contains(channel) else {
            status = "请填写有效的 Windows IP、用户名、主机名和蓝牙通道"; return false
        }
        stopProcesses()
        peerAddress = address
        peerUser = user.trimmingCharacters(in: .whitespaces)
        peerHost = host.trimmingCharacters(in: .whitespaces)
        bluetoothAddress = bluetooth.trimmingCharacters(in: .whitespaces)
        bluetoothChannel = channel
        for (key, value) in [("peerAddress",peerAddress),("peerUser",peerUser),("peerHost",peerHost),
                             ("bluetoothAddress",bluetoothAddress)] { UserDefaults.standard.set(value,forKey:key) }
        UserDefaults.standard.set(channel,forKey:"bluetoothChannel")
        pendingHostKey = nil; hostFingerprint = ""
        status = "已保存设备信息，请扫描并核对 SSH 指纹"
        return true
    }

    func scanHostFingerprint() {
        guard Self.validIPv4(peerAddress) else { status = "请先保存 Windows 局域网 IP"; return }
        let scan = Process(), output = Pipe()
        scan.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        scan.arguments = ["-T", "5", "-t", "ed25519", peerAddress]
        scan.standardInput = FileHandle.nullDevice
        scan.standardOutput = output; scan.standardError = FileHandle.nullDevice
        do { try scan.run(); scan.waitUntilExit() }
        catch { status = "扫描 SSH 指纹失败：\(error.localizedDescription)"; return }
        let rows = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).split(separator:"\n")
        guard let parts = rows.map({ $0.split(separator:" ") }).first(where: { $0.count >= 3 && $0[1] == "ssh-ed25519" }) else {
            status = "没有找到 Windows 的 SSH 服务，请检查 IP 和端口 22"; return
        }
        let candidate = "\(parts[1]) \(parts[2])"
        let temporary = support.appendingPathComponent("Keys/host-candidate.pub")
        do { try candidate.write(to:temporary,atomically:true,encoding:.utf8) }
        catch { status = error.localizedDescription; return }
        defer { try? files.removeItem(at:temporary) }
        let fingerprintProcess = Process(), fingerprintOutput = Pipe()
        fingerprintProcess.executableURL = URL(fileURLWithPath:"/usr/bin/ssh-keygen")
        fingerprintProcess.arguments = ["-lf",temporary.path,"-E","sha256"]
        fingerprintProcess.standardOutput = fingerprintOutput
        fingerprintProcess.standardError = FileHandle.nullDevice
        do { try fingerprintProcess.run(); fingerprintProcess.waitUntilExit() }
        catch { status = error.localizedDescription; return }
        guard fingerprintProcess.terminationStatus == 0,
              let fingerprint = String(decoding:fingerprintOutput.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
                .split(separator:" ").dropFirst().first else {
            status = "Windows 主机指纹格式无效"; return
        }
        pendingHostKey = candidate
        hostFingerprint = String(fingerprint)
        status = "请与 Windows 显示的 SHA256 指纹核对，再点击信任"
    }

    func trustScannedHost() {
        guard let pendingHostKey, !hostFingerprint.isEmpty else { return }
        do {
            try "LocalInputRouterPeer \(pendingHostKey)\n".write(
                to:support.appendingPathComponent("Keys/known_hosts"),atomically:true,encoding:.utf8)
            self.pendingHostKey = nil
            status = "主机指纹已保存；Windows 安装接收端后可连接"
        } catch { status = "无法保存主机指纹：\(error.localizedDescription)" }
    }

    private func prepareReceivers(ip: String) {
        guard let token = try? String(contentsOf:support.appendingPathComponent("trackpad-token"),encoding:.utf8),
              !token.isEmpty else { status = "本机输入认证令牌未生成"; return }
        let script = "$ErrorActionPreference='Stop';$d=Join-Path $env:LOCALAPPDATA 'LocalInputRouter';New-Item -ItemType Directory -Path $d -Force|Out-Null;$p=Join-Path $d 'trackpad.token';[IO.File]::WriteAllText($p,'\(token)',[Text.UTF8Encoding]::new($false));icacls.exe $p /inheritance:r /grant:r ((whoami)+':F') 'SYSTEM:F'|Out-Null;foreach($n in @('LocalInputRouter-Trackpad','LocalInputRouter-Voice','LocalInputRouter-Clipboard')){if(Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue;Start-ScheduledTask -TaskName $n}}"
        let encoded = script.data(using:.utf16LittleEndian)!.base64EncodedString()
        let process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
        process.arguments = sshArguments() + [peerUser + "@" + ip,
            "powershell.exe -NoProfile -NonInteractive -EncodedCommand " + encoded]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        lookup = process
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.lookup === ended else { return }
                self.lookup = nil
                if ended.terminationStatus == 0, self.running { self.launch(ip:ip) }
                else { self.waitForDirect() }
            }
        }
        do { try process.run() }
        catch { lookup = nil; status = "Windows 接收端设置失败：\(error.localizedDescription)" }
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
                keystroke(F18) = switchToScreen(Local-Router-Windows)
                keystroke(F19) = switchToScreen(Local-Router-Mac)
                keystroke(\(emergencyShortcut.deskflow)) = switchToScreen(Local-Router-Mac)
            end
            """.write(to: config, atomically: true, encoding: .utf8)
            let settings = support.appendingPathComponent("server.ini")
            try """
            [core]
            computerName=Local-Router-Mac
            coreMode=2
            processMode=0
            interface=127.0.0.1
            port=24900
            [computer_Local-Router-Mac]
            name=Local-Router-Mac
            [computer_Local-Router-Windows]
            name=Local-Router-Windows
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
                .appendingPathComponent("Contents/Helpers/InputRouterDeskflow")
            process.arguments = ["server", "--settings", settings.path]
            var env = ProcessInfo.processInfo.environment
            env["TMPDIR"] = runtime.path + "/"
            env["DYLD_INSERT_LIBRARIES"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VoicePassthrough.dylib").path
            env["QT_PLUGIN_PATH"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Deskflow.app/Contents/PlugIns").path
            process.environment = env
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
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.engine === process else { return }
                    self.stopProcesses()
                    self.status = "转发已停止，输入已回到 Mac（\(process.terminationStatus)）"
                }
            }
            try process.run()
            _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "输入路由保持连接" as CFString, &displayAssertion)
            controls.reset()
            controls.configure(available: false, pid: process.processIdentifier)
            status = "正在建立安全连接 · " + connectionRoute
            connectIPC(path: runtime.appendingPathComponent("deskflow-core").path, attempt: 0)
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = sshArguments() + ["-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                "-N", "-R", "127.0.0.1:24900:127.0.0.1:24900",
                "-L", "127.0.0.1:24901:127.0.0.1:24901",
                "-L", "127.0.0.1:24903:127.0.0.1:24903",
            "-L", "127.0.0.1:24904:127.0.0.1:24904", peerUser + "@" + ip]
            let errorLog = support.appendingPathComponent("ssh-error.log")
            files.createFile(atPath: errorLog.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            ssh.standardOutput = FileHandle.nullDevice
            ssh.standardError = try FileHandle(forWritingTo: errorLog)
            tunnel = ssh
            ssh.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.tunnel === process else { return }
                    self.stopProcesses()
                    self.status = self.transport == .bluetooth ? "蓝牙连接中断，已返回 Mac；请确认两端蓝牙已打开，正在重连" : "连接中断，已返回 Mac，正在重连"
                }
            }
            try ssh.run()
            trackpad.start(tokenURL: support.appendingPathComponent("trackpad-token"))
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
                    if line.hasPrefix("versionMismatch=") {
                        self.sendIPC("hello=" + line.dropFirst(16), connection)
                    } else if line == "connectionState=Connected" {
                        self.pendingDestination = nil
                        self.retryCount = 0
                        self.connected = true; self.status = self.peerHost + " 已连接 · " + self.connectionRoute
                        self.clipboard.start(tokenURL: self.support.appendingPathComponent("trackpad-token"))
                        self.armControls()
                        if self.desired == .windows { self.select(.windows) }
                        self.writeState(request: "connected")
                    } else if line == "connectionState=Listening" {
                        self.clipboard.stop()
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
        logBuffer += text
        while let end = logBuffer.firstIndex(of: "\n") {
            let line = String(logBuffer[..<end])
            logBuffer.removeSubrange(...end)
            if line.contains("Local input voice passthrough loaded") {
                voiceKeysReady = true; controls.setVoiceEnabled(voiceReady)
            }
            if line.contains("switch from \"Local-Router-Mac\" to \"Local-Router-Windows\"") { didSwitch(.windows) }
            if line.contains("switch from \"Local-Router-Windows\" to \"Local-Router-Mac\"") { didSwitch(.mac) }
            if line.contains("FATAL") || line.contains("failed to create quartz event tap") || line.contains("failed to register hotkey") {
                stopProcesses(); status = "转发后端无法捕获输入，请授权后重试"
            }
        }
    }

    func select(_ target: InputDestination) {
        desired = target
        if connected && target == .windows && destination != .windows {
            activateRDPWindow()
            _ = voice.prepare()
        }
        if connected && destination != target { expectSwitch(target); controls.select(target) }
        else if connected { pendingDestination = nil; return }
        else if target == .mac { stop() }
        else { running = true; nextRetry = .distantPast; check() }
    }

    private func expectSwitch(_ target: InputDestination) {
        guard destination != target else { pendingDestination = nil; return }
        pendingDestination = target
        status = target == .windows ? "正在将输入切换到 \(peerHost)…" : "正在将输入切回 Mac…"
        writeState(request: "switching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pendingDestination == target, self.destination != target else { return }
            self.stop()
            self.status = "切换未收到确认，输入已保留在 Mac，请重新连接"
        }
    }

    private func didSwitch(_ target: InputDestination) {
        if target == .mac { voice.leave() }
        destination = target; controls.confirm(target); trackpad.setRouting(target == .windows)
        if target == .mac, let previousRDPApp {
            self.previousRDPApp = nil
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.rdc.macos" {
                previousRDPApp.activate(options: [])
            }
        }
        updateRDPPointer()
        localCursor.setRouting(target == .windows && !rdpPointer)
        if pendingDestination == target { pendingDestination = nil }
        status = target == .windows ? "键盘与触控板正在控制 \(peerHost)" : "键盘与触控板已回到 Mac"
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
        localCursor.setRouting(false)
        voice.leave(); voiceTransport.stop(); voiceReady = false; voiceKeysReady = false
        clipboard.stop()
        let hadEngine = engine != nil
        controls.reset()
        trackpad.stop(); gesturesReady = false; gesturesStatus = "Windows 原生触控通道未连接"
        roundTripMs = -1; controls.setNativeGestures(false)
        ipc?.cancel(); ipc = nil
        for process in [guardian, lookup, engine, tunnel].compactMap({ $0 }) {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        guardian = nil; lookup = nil; engine = nil; tunnel = nil; logBuffer = ""
        connected = false; destination = .mac; pendingDestination = nil; usingConfiguredSSH = false
        if hadEngine {
            if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func shutdown() {
        stop(); trackpad.stopCapture(); controls.remove(); timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private func updateRDPPointer() {
        var enabled = false
        rdpFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        rdpWindowTitle = ""
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.microsoft.rdc.macos" {
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
                enabled = rdpWindowTitle == peerHost
            }
        }
        guard enabled != rdpPointer else { return }
        rdpPointer = enabled; controls.setRDPPointer(enabled)
        localCursor.setRouting(destination == .windows && !enabled)
    }

    private func activateRDPWindow() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.rdc.macos").first else { return }
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
            guard title as? String == peerHost else { continue }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                previousRDPApp = NSWorkspace.shared.frontmostApplication
            }
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            rdpActivation = "\(peerHost) raise=\(raised.rawValue) activated=\(activated)"
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

    private func writeState(request: String) {
        let snapshot: [String: Any] = ["request": request, "pid": getpid(),
            "destination": destination.rawValue, "connected": connected, "status": status,
            "running": running,
            "toggleShortcutValue": ["keyCode": toggleShortcut.keyCode, "modifiers": toggleShortcut.modifiers],
            "emergencyShortcutValue": ["keyCode": emergencyShortcut.keyCode, "modifiers": emergencyShortcut.modifiers],
            "address": address, "transport": transport.rawValue, "connectionRoute": connectionRoute, "usingConfiguredSSH": usingConfiguredSSH, "accessibility": accessibility, "inputMonitoring": monitoring,
            "activeDisplay": displayAvailable, "corePID": engine?.processIdentifier ?? 0,
            "localCursorHidden": localCursor.hidden, "localCursorVisible": DJFCursorIsVisible() != 0,
            "rdpPointer": rdpPointer, "rdpFrontmost": rdpFrontmost, "rdpWindowTitle": rdpWindowTitle, "rdpActivation": rdpActivation,
            "lastRecovery": controls.recoveryReason,
            "voiceInput": voice.snapshot,
            "clipboardReady": clipboardReady, "clipboardStatus": clipboardStatus,
            "tunnelPID": tunnel?.processIdentifier ?? 0, "guardianPID": guardian?.processIdentifier ?? 0,
            "toggleShortcut": toggleShortcut.title, "emergencyShortcut": emergencyShortcut.title,
            "pointerGain": pointerGain, "scrollGain": scrollGain, "switchGesture": switchGesture.rawValue,
            "voiceReady": voiceReady, "voiceKeysReady": voiceKeysReady, "voiceStatus": voiceStatus, "gesturesStatus": gesturesStatus, "nativeTrackpad": trackpad.snapshot,
            "routedMotion": controls.motionSnapshot,
            "pendingDestination": pendingDestination?.rawValue ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
            try? data.write(to: support.appendingPathComponent("status.json"), options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(.init("org.localinputrouter.app.state"), object: nil, deliverImmediately: true)
        }
    }

    func openPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
