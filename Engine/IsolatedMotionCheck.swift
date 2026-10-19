// Test harness only. Isolate motion samples; keys (including emergency Esc) pass.
import CoreGraphics
import Foundation
let marker: Int64 = 0x444A4654455354
var blocked = 0
let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == 0x444A4654455354 { return Unmanaged.passUnretained(event) }
        blocked += 1
        return nil
    }, userInfo: nil) else { print("Cannot isolate test motion"); exit(1) }
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
let test = Process()
test.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
test.arguments = Array(CommandLine.arguments.dropFirst())
try test.run()
let deadline = Date().addingTimeInterval(55)
while test.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
CFMachPortInvalidate(tap)
if test.isRunning { test.interrupt(); print("Timeout; pointer released"); exit(1) }
print("Other motion samples isolated: \(blocked); pointer released")
exit(test.terminationStatus)
