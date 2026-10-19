// Integration-test motion source: no clicks or keys; checks Mac cursor isolation.
import CoreGraphics
import Foundation
let dx = Int64(CommandLine.arguments[1])!
let dy = Int64(CommandLine.arguments[2])!
let count = Int(CommandLine.arguments[3])!
let before = CGEvent(source: nil)!.location
for _ in 0..<count {
    let motion = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: before, mouseButton: .left)!
    motion.setIntegerValueField(.eventSourceUserData, value: 0x444A4654455354)
    motion.setIntegerValueField(.mouseEventDeltaX, value: dx)
    motion.setIntegerValueField(.mouseEventDeltaY, value: dy)
    motion.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
}
Thread.sleep(forTimeInterval: 0.15)
let after = CGEvent(source: nil)!.location
if before != after { print("FAIL: local cursor moved from \(before) to \(after)"); exit(1) }
print("PASS: \(count) motion samples (\(dx),\(dy)); local Mac cursor unchanged")
