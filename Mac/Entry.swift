import AppKit
import ApplicationServices
import Carbon
import Darwin

@main
@MainActor
enum RouterEntry {
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
        if args.count > 1 && ["--status", "--switch", "--stop", "--reconnect", "--quit", "--pointer-gain", "--scroll-gain", "--transport", "--modifier-pulse", "--voice-path-check"].contains(args[1]) {
            let command = args[1] == "--switch" ? (args.count == 3 ? args[2] : "invalid") : String(args[1].dropFirst(2))
            guard ["status", "mac", "windows", "stop", "reconnect", "quit", "pointer-gain", "scroll-gain", "transport", "modifier-pulse", "voice-path-check"].contains(command) else {
                print("Usage: --status | --switch mac/windows | --stop | --reconnect | --quit"); exit(1)
            }
            if command == "transport" && (args.count != 3 || RouterTransport(rawValue: args[2]) == nil) {
                print("Usage: --transport direct/bluetooth"); exit(1)
            }
            if command == "pointer-gain" || command == "scroll-gain" {
                guard args.count == 3, let value = Double(args[2]), value.isFinite, (0.1...10).contains(value) else {
                    print("Pointer gain must be between 0.1 and 10."); exit(1)
                }
            }
            let request = UUID().uuidString
            DistributedNotificationCenter.default().postNotificationName(.init("org.localinputrouter.app.control"),
                object: nil, userInfo: ["command": command, "request": request, "value": args.last ?? ""], deliverImmediately: true)
            let state = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/LocalInputRouter/status.json")
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
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        let recover = {
            kill(core, SIGKILL)
            kill(tunnel, SIGTERM)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
            exit(0)
        }
        source.setEventHandler(handler: recover)
        source.resume()
        if kill(parent, 0) != 0 { recover() }
        withExtendedLifetime(source) { dispatchMain() }
    }
}
