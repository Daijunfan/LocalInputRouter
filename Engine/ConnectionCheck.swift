// Test the production controller against the actual signed backend and Windows.
// Run from the already-authorized development terminal, not as a substitute for
// the installed app's macOS privacy authorization.
import AppKit
import Darwin
import Carbon

@main
@MainActor
enum ConnectionCheck {
    static func main() {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--guard-parent" {
            let executable = "/Applications/DJF 输入路由.app/Contents/MacOS/DJFInputRouter"
            var arguments = ([executable] + CommandLine.arguments.dropFirst()).map { strdup($0) }
            arguments.append(nil)
            executable.withCString { _ = execv($0, &arguments) }
            exit(1)
        }
        let router = RouterController()
        defer { router.shutdown() }
        let until = Date().addingTimeInterval(30)
        while !router.connected && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard router.connected else { print("CONNECTION FAILED: \(router.status)"); exit(1) }
        print("CONNECTED: \(router.address) / DJF-Windows; native IPC and signed backend ready")
        func toggle() {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: down)!
                event.flags = down ? [.maskControl, .maskAlternate] : []
                event.post(tap: .cghidEventTap)
            }
        }
        toggle()
        let switched = Date().addingTimeInterval(2)
        while router.destination != .windows && Date() < switched {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard router.destination == .windows else { print("WINDOWS SWITCH FAILED"); exit(1) }
        let before = CGEvent(source: nil)!.location
        let motion = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: before, mouseButton: .left)!
        motion.setIntegerValueField(.mouseEventDeltaX, value: 5)
        motion.setIntegerValueField(.mouseEventDeltaY, value: 3)
        motion.post(tap: .cghidEventTap)
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        scroll.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let after = CGEvent(source: nil)!.location
        guard before == after else { print("LOCAL CURSOR MOVED WHILE ROUTING TO WINDOWS"); exit(1) }
        print("PASS: actual shortcut and mouse/scroll forwarding; local Mac cursor unchanged")
        toggle()
        let returned = Date().addingTimeInterval(2)
        while router.destination != .mac && Date() < returned {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard router.destination == .mac else { print("MAC RETURN FAILED"); exit(1) }
        print("PASS: actual shortcut Mac -> DJF-Windows -> Mac backend switch acknowledged")
    }
}
