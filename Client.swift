import AppKit
import Combine
import Carbon
import Darwin

enum InputDestination: String { case mac, windows }
enum RouterTransport: String, CaseIterable {
    case direct, bluetooth
    var title: String { self == .direct ? "局域网（自动）" : "蓝牙直连" }
    var detail: String {
        self == .direct ? "优先在当前局域网直连；失败时尝试备用 IP，再查询登记地址。" : "通过已配对的蓝牙连接；Mac 继续使用 Wi-Fi 上网。"
    }
}

/// UI adapter only. Input capture, speech, gestures and SSH stay in the agent.
@MainActor
final class InputRouterClient: ObservableObject {
    @Published private var record: [String: Any] = [:]
    @Published private var launchError = ""
    private var timer: Timer?
    private var stateObserver: NSObjectProtocol?
    private var lastStateData: Data?
    private var launching = false
    private var pending: [[String: Any]] = []
    private let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DJF Input Router/status.json")

    var destination: InputDestination { InputDestination(rawValue: record["destination"] as? String ?? "mac") ?? .mac }
    var pendingDestination: InputDestination? { (record["pendingDestination"] as? String).flatMap(InputDestination.init(rawValue:)) }
    var connected: Bool { alive && (record["connected"] as? Bool ?? false) }
    var running: Bool { alive && (record["running"] as? Bool ?? false) }
    var status: String { launchError.isEmpty ? (alive ? record["status"] as? String ?? "正在连接输入路由" : "正在启动输入路由") : launchError }
    var address: String { record["address"] as? String ?? "" }
    var lanAddress: String { record["lanAddress"] as? String ?? "" }
    var connectionRoute: String { record["connectionRoute"] as? String ?? transport.title }
    var desktopTitle: String { record["desktopMode"] as? String == "console" ? "共享实体桌面（USB 键盘）" : "Windows App（RDP）" }
    var consoleStatus: String { record["consoleStatus"] as? String ?? "共享实体桌面让 Windows USB 键盘与远程画面操作同一桌面。" }
    var openingConsole: Bool { record["openingConsole"] as? Bool ?? false }
    var accessibility: Bool { record["accessibility"] as? Bool ?? true }
    var transport: RouterTransport { RouterTransport(rawValue: record["transport"] as? String ?? "direct") ?? .direct }
    var pointerGain: Double { record["pointerGain"] as? Double ?? 1 }
    var scrollGain: Double { record["scrollGain"] as? Double ?? 1.5 }
    var dragTapInterval: Double { record["dragTapInterval"] as? Double ?? 0.20 }
    var gesturesReady: Bool { native["ready"] as? Bool ?? false }
    var roundTripMs: Double { gesturesReady ? native["roundTripMedianMs"] as? Double ?? -1 : -1 }
    var gesturesStatus: String { record["gesturesStatus"] as? String ?? (gesturesReady ? "Windows 原生触控板已连接" : "正在连接 Windows 原生触控板") }
    var voiceReady: Bool { record["voiceReady"] as? Bool ?? false }
    var clipboardReady: Bool { alive && record["clipboardReady"] as? Bool == true }
    var clipboardStatus: String { record["clipboardStatus"] as? String ?? "剪贴板共享未连接" }
    var voiceStatus: String { record["voiceStatus"] as? String ?? "Mac 豆包语音：Fn 按住说话，右 Option 免按" }
    var toggleShortcut: RouterShortcut { shortcut("toggleShortcutValue", fallback: .toggle) }
    var emergencyShortcut: RouterShortcut { shortcut("emergencyShortcutValue", fallback: .emergency) }
    var switchGesture: String { record["switchGesture"] as? String ?? "threeDouble" }
    private var native: [String: Any] { record["nativeTrackpad"] as? [String: Any] ?? [:] }
    private var alive: Bool { (record["pid"] as? Int).map { $0 > 1 && kill(pid_t($0), 0) == 0 } ?? false }
    var appRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.djf.inputrouter").isEmpty }

    init() {
        refresh()
        stateObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.djf.inputrouter.state"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        if let data = try? Data(contentsOf: stateURL), data != lastStateData,
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lastStateData = data
            let value = Self.uiRecord(raw)
            if !NSDictionary(dictionary: record).isEqual(to: value) { record = value }
        }
        if alive, !pending.isEmpty {
            let commands = pending; pending.removeAll()
            commands.forEach(post)
        }
        if !appRunning && !launching { pending.removeAll() }
    }

    // Diagnostic counters change at trackpad frequency but are not UI state.
    static func uiRecord(_ raw: [String: Any]) -> [String: Any] {
        let keys = ["pid", "destination", "pendingDestination", "connected", "running", "status", "address", "lanAddress", "connectionRoute", "usingConfiguredSSH", "accessibility", "transport", "pointerGain", "scrollGain", "dragTapInterval", "switchGesture", "voiceReady", "voiceStatus", "clipboardReady", "clipboardStatus", "gesturesStatus", "toggleShortcutValue", "emergencyShortcutValue", "desktopMode", "consoleStatus", "openingConsole"]
        var result = raw.filter { keys.contains($0.key) }
        let native = raw["nativeTrackpad"] as? [String: Any] ?? [:]
        let rtt = native["roundTripMedianMs"] as? Double ?? -1
        let ready = native["ready"] as? Bool ?? false
        result["nativeTrackpad"] = ["ready": ready, "roundTripMedianMs": ready ? (rtt * 10).rounded() / 10 : -1]
        if !ready && raw["gesturesStatus"] as? String == "Windows 原生多指触控已连接" {
            result["gesturesStatus"] = "Windows 原生触控通道未连接"
        }
        return result
    }

    private func ensureAgent() {
        guard !launching, !appRunning else { return }
        launching = true; launchError = ""
        // Keep the existing authorized application path and code identity.
        let agent = URL(fileURLWithPath: "/Applications/DJF 输入路由.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--toolbox"]
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: agent, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launching = false
                if let error { self.launchError = "输入路由无法启动：" + error.localizedDescription }
                self.refresh()
            }
        }
    }

    private func command(_ name: String, value: String = "", toggle: Bool? = nil) {
        ensureAgent()
        var info: [String: Any] = ["command": name, "request": UUID().uuidString, "value": value]
        if let toggle { info["toggle"] = toggle }
        if alive { post(info) } else { pending.append(info) }
    }

    private func post(_ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(.init("com.djf.inputrouter.control"),
            object: nil, userInfo: info, deliverImmediately: true)
    }

    private func shortcut(_ key: String, fallback: RouterShortcut) -> RouterShortcut {
        guard let value = record[key], let data = try? JSONSerialization.data(withJSONObject: value),
              let result = try? JSONDecoder().decode(RouterShortcut.self, from: data) else { return fallback }
        return result
    }

    func select(_ target: InputDestination) { command(target.rawValue) }
    func stop() { command("stop") }
    func reconnect() { command("reconnect") }
    func openConsoleDesktop() { command("open-console") }
    func useRDPDesktop() { command("use-rdp") }
    func emergency() { command("emergency") }
    func openPermissions() { command("open-permissions") }
    func setTransport(_ value: RouterTransport) { command("transport", value: value.rawValue) }
    func setLANAddress(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.isEmpty || (parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }) else { return false }
        command("lan-address", value: value)
        return true
    }
    func setSwitchGesture(_ value: String) { command("switch-gesture", value: value) }
    func setPointerGain(_ value: Double) -> Bool {
        guard value.isFinite && (0.1...10).contains(value) else { return false }
        command("pointer-gain", value: String(value)); record["pointerGain"] = (value * 100).rounded() / 100; return true
    }
    func setScrollGain(_ value: Double) -> Bool {
        guard value.isFinite && (0.1...10).contains(value) else { return false }
        command("scroll-gain", value: String(value)); record["scrollGain"] = (value * 100).rounded() / 100; return true
    }
    func setDragTapInterval(_ value: Double) -> Bool {
        guard value.isFinite && (0.01...0.30).contains(value) else { return false }
        command("drag-tap-interval", value: String(value)); record["dragTapInterval"] = (value * 100).rounded() / 100; return true
    }
    func setShortcut(toggle: Bool, value: RouterShortcut) -> String? {
        guard value.valid else { return "字母和普通按键至少需要一个修饰键；也可以使用 F 功能键。" }
        guard value != (toggle ? emergencyShortcut : toggleShortcut) else { return "切换键和紧急返回键不能相同。" }
        if let data = try? JSONEncoder().encode(value) { command("set-shortcut", value: data.base64EncodedString(), toggle: toggle) }
        return nil
    }
    func launch() { ensureAgent() }
    func quitApp() {
        pending.removeAll()
        if appRunning { command("quit") }
    }

    deinit {
        timer?.invalidate()
        if let stateObserver { DistributedNotificationCenter.default().removeObserver(stateObserver) }
    }
}
