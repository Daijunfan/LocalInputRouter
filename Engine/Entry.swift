import AppKit
import ApplicationServices
import Carbon
import Darwin

@main
@MainActor
enum RouterEntry {
    private static var instanceLock: Int32 = -1
    static func main() {
        let args = CommandLine.arguments
        if args.count == 5 && args[1] == "--guard-parent",
            let parent = Int32(args[2]), let core = Int32(args[3]), let tunnel = Int32(args[4]),
            parent > 1 && core > 1 && tunnel > 1 {
            watchParent(parent, core: core, tunnel: tunnel)
        }
        if args.contains("--diagnose") {
            var displays: UInt32 = 0
            _ = CGGetActiveDisplayList(0, nil, &displays)
            let data: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "unbundled",
                "accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(),
                "activeDisplays": displays, "secureInput": IsSecureEventInputEnabled()]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        if args.contains("--self-test") { exit(runInputChecks()) }
        if args.contains("--self-test-custom") { exit(runInputChecks(custom: true)) }
        if args.count > 1 && ["--status", "--switch", "--stop", "--reconnect", "--quit", "--pointer-gain", "--scroll-gain", "--drag-tap-interval", "--transport", "--switch-gesture", "--lan-address", "--modifier-pulse", "--voice-path-check", "--open-console", "--use-rdp", "--clear-console-password", "--console-check"].contains(args[1]) {
            let command = args[1] == "--switch" ? (args.count == 3 ? args[2] : "invalid") : String(args[1].dropFirst(2))
            guard ["status", "mac", "windows", "stop", "reconnect", "quit", "pointer-gain", "scroll-gain", "drag-tap-interval", "transport", "switch-gesture", "lan-address", "modifier-pulse", "voice-path-check", "open-console", "use-rdp", "clear-console-password", "console-check"].contains(command) else {
                print("Usage: --status | --switch mac/windows | --stop | --reconnect | --quit"); exit(1)
            }
            if command == "transport" && (args.count != 3 || RouterTransport(rawValue: args[2]) == nil) {
                print("Usage: --transport direct/bluetooth"); exit(1)
            }
            if command == "switch-gesture" && (args.count != 3 || TouchSwitchGesture(rawValue: args[2]) == nil) {
                print("Usage: --switch-gesture threeDouble/fourSingle"); exit(1)
            }
            if command == "lan-address" && (args.count != 3 || (!args[2].isEmpty && !RouterController.validIPv4(args[2]))) {
                print("Usage: --lan-address IPv4 (or an empty string to clear)"); exit(1)
            }
            if command == "pointer-gain" || command == "scroll-gain" {
                guard args.count == 3, let value = Double(args[2]), value.isFinite, (0.1...10).contains(value) else {
                    print("Pointer gain must be between 0.1 and 10."); exit(1)
                }
            }
            if command == "drag-tap-interval" {
                guard args.count == 3, let value = Double(args[2]), value.isFinite, (0.01...0.30).contains(value) else {
                    print("Drag tap interval must be between 0.01 and 0.30 seconds."); exit(1)
                }
            }
            let request = UUID().uuidString
            DistributedNotificationCenter.default().postNotificationName(.init("com.djf.inputrouter.control"),
                object: nil, userInfo: ["command": command, "request": request, "value": args.last ?? ""], deliverImmediately: true)
            let state = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/DJF Input Router/status.json")
            let deadline = Date().addingTimeInterval(3)
            repeat {
                if let data = try? Data(contentsOf: state),
                    let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    record["request"] as? String == request {
                    print(String(decoding: data, as: UTF8.self)); return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            } while Date() < deadline
            print("Input router is not running or is not responding."); exit(1)
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DJF Input Router")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        instanceLock = open(support.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        guard instanceLock >= 0 && flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            if !args.contains("--background") {
                DistributedNotificationCenter.default().postNotificationName(.init("com.djf.inputrouter.control"),
                    object: nil, userInfo: ["command": "show-window"], deliverImmediately: true)
            }
            return
        }
        _ = fcntl(instanceLock, F_SETFD, FD_CLOEXEC)
        RouterAgentApp.main()
    }

    static func modifierPulse() {
            // Used only with RemoteModifierProbe, which traps the test keys.
            for (modifier, key, flags) in [(kVK_Command, kVK_F13, CGEventFlags.maskCommand),
                (kVK_Command, kVK_F14, CGEventFlags([.maskCommand, .maskShift])),
                (kVK_Control, kVK_F15, CGEventFlags.maskControl)] {
                let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(modifier), keyDown: true)!
                down.type = .flagsChanged; down.flags = flags; down.post(tap: .cghidEventTap)
                for pressed in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: pressed)!
                    event.flags = flags; event.post(tap: .cghidEventTap)
                }
                let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(modifier), keyDown: false)!
                up.type = .flagsChanged; up.flags = []; up.post(tap: .cghidEventTap)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
    }

    static func watchParent(_ parent: pid_t, core: pid_t, tunnel: pid_t) -> Never {
        let queue = DispatchQueue(label: "com.djf.inputrouter.guard")
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
        let recover = {
            kill(core, SIGKILL)
            kill(tunnel, SIGTERM)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
            // Normal Quit stops this guard first. Unexpected exits also recover
            // a manually opened app that was not launched by launchd.
            let reopen = Process()
            reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            reopen.arguments = ["-g", "-a", Bundle.main.bundlePath, "--args", "--background"]
            try? reopen.run()
            exit(0)
        }
        source.setEventHandler(handler: recover)
        source.resume()
        if kill(parent, 0) != 0 { recover() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let state = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DJF Input Router/status.json")
        timer.schedule(deadline: .now() + 10, repeating: 1)
        timer.setEventHandler {
            guard let data = try? Data(contentsOf: state),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["pid"] as? Int32 == parent,
                  let updated = value["updatedAt"] as? Double,
                  Date().timeIntervalSince1970 - updated > 8 else { return }
            // A live PID alone cannot detect a frozen AppKit event loop.
            kill(parent, SIGKILL)
        }
        timer.resume()
        withExtendedLifetime((source, timer)) { dispatchMain() }
    }
}
