// Integration fixture: inject touch timing through production InputControl,
// then forward its HID output through the running router to a disposable window.
import Foundation
import CoreGraphics
import Carbon

@main enum PointerRoutingLive {
    static let marker: Int64 = 0x444A4654455354
    static func main() {
        let control = InputControl()
        control.configure(available: true, pid: 0)
        control.confirm(.windows)
        let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask.max, callback: { proxy, type, event, info in
                let tag = event.getIntegerValueField(.eventSourceUserData)
                if tag == 0x444A4654455354 {
                    let result = Unmanaged<InputControl>.fromOpaque(info!).takeUnretainedValue().handle(proxy: proxy, type: type, event: event)
                    result?.takeUnretainedValue().setIntegerValueField(.eventSourceUserData, value: InputControl.dragMarker)
                    return result
                }
                if [InputControl.dragMarker, InputControl.releaseMarker].contains(tag) { return Unmanaged.passUnretained(event) }
                // Isolate this short fixture from physical pointer movement.
                if [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) { return nil }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(control).toOpaque())!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        defer { CFMachPortInvalidate(tap) }
        func settle(_ seconds: Double = 0.08) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        let before = CGEvent(source: nil)!.location
        func mouse(_ type: CGEventType, _ dx: Int64 = 0, _ dy: Int64 = 0) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: before, mouseButton: .left)!
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.setIntegerValueField(.mouseEventDeltaX, value: dx)
            e.setIntegerValueField(.mouseEventDeltaY, value: dy)
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap); settle()
        }
        if CommandLine.arguments.contains("drag") {
            mouse(.leftMouseUp)
            let time = ProcessInfo.processInfo.systemUptime
            control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: time)
            mouse(.leftMouseDown); mouse(.leftMouseUp)
            control.setTouchFrame(count: 0, x: 0, y: 0, time: time + 0.17)
            control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: time + 0.22)
            mouse(.mouseMoved, 13, 0)
            for _ in 0..<10 { mouse(.mouseMoved, 5, 3) }
            control.setTouchFrame(count: 0, x: 0, y: 0, time: time + 1.3); settle()
            for _ in 0..<3 { mouse(.mouseMoved, 5, 0) }
        } else {
            let dx = Int64(CommandLine.arguments[1])!, dy = Int64(CommandLine.arguments[2])!
            let count = Int(CommandLine.arguments[3])!
            for _ in 0..<count { mouse(.mouseMoved, dx, dy) }
        }
        settle(0.3)
        let after = CGEvent(source: nil)!.location
        let result: [String: Any] = ["macCursorUnchanged": before == after,
            "before": [before.x, before.y], "after": [after.x, after.y], "motion": control.motionSnapshot]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        if before != after { exit(1) }
    }
}
