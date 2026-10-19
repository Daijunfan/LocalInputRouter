import Foundation
import CoreGraphics
import Carbon
@main enum PrecisionChecks {
    static func main() {
        let cancel = MacVoiceEvents.cancellationEvents(trigger: UInt16(kVK_RightOption))
        precondition(cancel.map(\.type) == [.keyDown, .keyUp])
        precondition(cancel.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == kVK_Escape && $0.flags.isEmpty })
        let fnRelease = MacVoiceEvents.cancellationEvents(trigger: UInt16(kVK_Function))
        precondition(fnRelease.count == 1 && fnRelease[0].type == .flagsChanged && fnRelease[0].flags.isEmpty)
        for factor in [0.1, 0.5, 1.0, 1.25, 2.75, 10.0] {
            var gain = PointerGain(factor: factor)
            var x: Int64 = 0, y: Int64 = 0
            for _ in 0..<100 { let d = gain.scale(1, -1); x += d.0; y += d.1 }
            precondition(abs(Double(x) - 100 * factor) < 1.01 && x == -y)
            for _ in 0..<100 { let d = gain.scale(-1, 1); x += d.0; y += d.1 }
            precondition(abs(x) <= 1 && abs(y) <= 1)
        }
        let control = InputControl()
        control.configure(available: true, pid: 123)
        control.confirm(.windows)
        control.confirm(.mac)
        let option = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true)!
        option.type = .flagsChanged; option.flags = .maskAlternate
        precondition(control.guardLocal(option) != nil)
        precondition(control.handle(proxy: nil, type: .flagsChanged, event: option) != nil)
        var drag = TouchDragRelease()
        precondition(!drag.contactCount(1))
        precondition(drag.observe(.leftMouseDown) == .leftMouseDown)
        precondition(drag.observe(.leftMouseDragged) == .leftMouseDragged)
        precondition(drag.contactCount(0))
        precondition(!drag.contactCount(0)) // Release exactly once.
        precondition(drag.observe(.leftMouseDragged) == .mouseMoved)
        precondition(!drag.contactCount(1))
        precondition(drag.observe(.leftMouseDragged) == .mouseMoved) // Re-touch cannot re-lock.
        precondition(drag.observe(.leftMouseUp) == .leftMouseUp)
        precondition(drag.observe(.leftMouseDown) == .leftMouseDown)
        precondition(!drag.contactCount(0)) // An ordinary click is not a drag.
        drag.reset()
        _ = drag.observe(.leftMouseDragged)
        precondition(!drag.contactCount(0)) // No trackpad contact: leave a mouse alone.
        let release = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)!
        release.setIntegerValueField(.eventSourceUserData, value: InputControl.releaseMarker)
        precondition(control.handle(proxy: nil, type: .leftMouseUp, event: release) == nil)
        var scrollSamples: [(Double,Double,Bool)] = []
        control.onScroll = { scrollSamples.append(($0,$1,$2)) }
        control.confirm(.windows); control.setNativeGestures(true); control.setMacScroll(true); control.setScrollGain(1.5)
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 4, wheel2: 2, wheel3: 0)!
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        precondition(control.handle(proxy: nil, type: .scrollWheel, event: scroll) == nil)
        precondition(scrollSamples.count == 1 && scrollSamples[0].0 == 3 && scrollSamples[0].1 == 6 && scrollSamples[0].2)
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        precondition(control.handle(proxy: nil, type: .scrollWheel, event: scroll) == nil)
        precondition(scrollSamples.count == 2 && !scrollSamples[1].2)
        control.confirm(.mac)
        precondition(control.handle(proxy: nil, type: .scrollWheel, event: scroll) != nil && scrollSamples.count == 2)
        control.confirm(.windows); control.setRDPPointer(true)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 20, y: 30), mouseButton: .left)!
            precondition(control.handle(proxy: nil, type: type, event: event) != nil)
            precondition(event.getIntegerValueField(.eventSourceUserData) == InputControl.rdpPointerMarker)
            precondition(control.guardLocal(event) != nil)
        }
        let key = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_A), keyDown: true)!
        precondition(control.guardLocal(key) == nil, "RDP mouse passthrough must not leak routed keys to Mac")
        control.setRDPPointer(false)
        let ordinary = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        precondition(control.handle(proxy: nil, type: .leftMouseDown, event: ordinary) != nil)
        precondition(control.guardLocal(ordinary) == nil, "Physical-host routing still blocks local clicks")
        ordinary.setIntegerValueField(.eventSourceUserData, value: InputControl.rdpPointerMarker)
        precondition(control.guardLocal(ordinary) == nil, "Stale RDP events must not reach another Mac app")
        control.confirm(.mac)
        var tap = TapDrag()
        precondition(!tap.contact(count: 1, x: 0.5, y: 0.5, time: 1))
        precondition(!tap.contact(count: 0, x: 0, y: 0, time: 1.1))
        tap.nativePress() // A native tap click often follows the raw lift.
        precondition(!tap.contact(count: 1, x: 0.51, y: 0.5, time: 1.2))
        tap.nativePress() // The same click may arrive after the second touch.
        precondition(tap.armed && !tap.move(dx: 3, dy: 0))
        precondition(tap.move(dx: 10, dy: 0) && tap.dragging)
        precondition(tap.contact(count: 0, x: 0, y: 0, time: 1.8))
        precondition(!tap.contact(count: 0, x: 0, y: 0, time: 1.9))
        tap.reset()
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 2)
        _ = tap.contact(count: 0, x: 0, y: 0, time: 2.1)
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 2.7)
        precondition(!tap.armed && !tap.move(dx: 100, dy: 0))
        var frames = GestureFrameGate()
        precondition(!frames.shouldSend(count: 1))
        for _ in 0..<100 { precondition(!frames.shouldSend(count: 1)) }
        precondition(frames.shouldSend(count: 2) && frames.shouldSend(count: 3))
        precondition(frames.shouldSend(count: 1), "A gesture ending with one finger must release Windows contacts")
        precondition(!frames.shouldSend(count: 0))
        precondition(frames.shouldSend(count: 4)); frames.reset()
        precondition(!frames.shouldSend(count: 0))
        tap.reset()
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 3)
        _ = tap.contact(count: 0, x: 0, y: 0, time: 3.1)
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 3.2)
        _ = tap.contact(count: 2, x: 0.5, y: 0.5, time: 3.25)
        precondition(!tap.armed && !tap.move(dx: 100, dy: 0))
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 3.26)
        _ = tap.contact(count: 0, x: 0, y: 0, time: 3.27)
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 3.3)
        precondition(!tap.armed, "A remaining finger after a gesture must not count as a first tap")
        print("PASS: balanced voice cancellation; fixed pointer/scroll gain, local isolation, double-tap drag, lift release, ordinary movement and multi-finger exclusion")
    }
}
