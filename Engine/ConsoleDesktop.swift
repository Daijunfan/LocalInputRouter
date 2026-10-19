import AppKit
import CryptoKit
import Network

enum RemoteDesktopMode: String {
    case rdp, console
    var bundleIdentifier: String {
        self == .rdp ? "com.microsoft.rdc.macos" : "com.djf.inputrouter"
    }
    var title: String { self == .rdp ? "Windows App（RDP）" : "共享实体桌面（USB 键盘）" }
    static func matches(bundle: String, title: String) -> Bool {
        if bundle == RemoteDesktopMode.rdp.bundleIdentifier { return title == "DJF-Windows" }
        return bundle == RemoteDesktopMode.console.bundleIdentifier && title == "DJF-Windows"
    }
    static func isViewer(_ bundle: String) -> Bool {
        bundle == RemoteDesktopMode.rdp.bundleIdentifier || bundle == RemoteDesktopMode.console.bundleIdentifier
    }
    static func nativePointer(bundle: String, title: String, destination: InputDestination) -> Bool {
        matches(bundle: bundle, title: title) && (bundle == rdp.bundleIdentifier || destination == .mac)
    }
}

enum ConsoleDesktop {
    static let port = 24805
    @MainActor private static var viewer: ConsoleWindow?
    @MainActor private static var probe: ConsoleWindow?
    @MainActor static func checkConnection(_ completed: @escaping (Bool) -> Void) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        var finished = false
        func finish(_ ready: Bool) {
            guard !finished else { return }
            finished = true; connection.cancel(); completed(ready)
        }
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 12, maximumLength: 12) { data, _, _, _ in
                        MainActor.assumeIsolated {
                            finish(data.map { String(decoding: $0.prefix(4), as: UTF8.self) == "RFB " } ?? false)
                        }
                    }
                case .failed: finish(false)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(false) }
    }
    static var command: String {
        let script = "& (Join-Path $env:LOCALAPPDATA 'DJF-Windows\\ConsoleDesktop.ps1')"
        return "powershell -NoProfile -ExecutionPolicy RemoteSigned -EncodedCommand " + script.data(using: .utf16LittleEndian)!.base64EncodedString()
    }
    @MainActor static func openViewer(onStatus: ((String) -> Void)? = nil) {
        if let viewer { viewer.present(); return }
        guard let password = password() else { onStatus?("共享桌面的设备密钥尚未配置"); return }
        let window = ConsoleWindow(password: password)
        window.onStatus = onStatus
        window.onClose = { viewer = nil; onStatus?("共享桌面已关闭") }
        viewer = window
        window.present()
    }
    @MainActor static func activateViewer() { viewer?.present() }
    @MainActor static func checkRender(_ completed: @escaping ([String: Any]) -> Void) {
        guard probe == nil, let password = password() else { completed(["error": "Console check is unavailable"]); return }
        let window = ConsoleWindow(password: password)
        probe = window
        // Exercise the production decoder without showing or activating a window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            window.measureFrame { result in
                window.window?.close(); probe = nil
                completed(result)
            }
        }
    }
    private static func password() -> String? {
        let tokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DJF Input Router/trackpad-token")
        guard var token = try? Data(contentsOf: tokenURL), !token.isEmpty else { return nil }
        token.append(Data("DJF console desktop".utf8))
        return String(Data(SHA256.hash(data: token)).base64EncodedString().prefix(8))
    }
    @MainActor static func clearCopiedPassword() {
        if let password = password(), NSPasteboard.general.string(forType: .string) == password {
            NSPasteboard.general.clearContents()
        }
    }
}
