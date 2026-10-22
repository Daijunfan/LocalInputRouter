import AppKit
import Carbon

@main @MainActor enum NativeRDPSpeechChecks {
    static func main() {
        // Capture only this test's replayed modifiers; no test keys reach an app.
        let replays = UnsafeMutablePointer<[CGKeyCode]>.allocate(capacity: 1)
        replays.initialize(to: [])
        let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: { _, _, event, context in
                if MacVoiceEvents.owns(event), event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                    context!.assumingMemoryBound(to: [CGKeyCode].self).pointee.append(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: replays)!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        defer { CFMachPortInvalidate(tap); CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            replays.deinitialize(count: 1); replays.deallocate() }
        let control = InputControl()
        control.configure(available: true, pid: getpid()); control.confirm(.mac)
        control.setRDPPointer(true); control.setVoiceEnabled(true)
        var voiceKeys = [CGKeyCode]()
        var prepared = [CGKeyCode](), discarded = 0
        control.onVoicePrepare = { prepared.append($0); return true }
        control.onVoiceDiscard = { discarded += 1 }
        control.onVoiceEvent = { voiceKeys.append(CGKeyCode($0.getIntegerValueField(.keyboardEventKeycode))) }
        func handle(_ key: Int, _ type: CGEventType, _ flags: CGEventFlags = []) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: type != .keyUp)!
            event.type = type; event.flags = flags
            return control.handle(proxy: nil, type: type, event: event) != nil
        }
        func wait(_ seconds: Double = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        precondition(handle(kVK_ANSI_A, .keyDown))
        precondition(handle(kVK_RightOption, .flagsChanged, .maskAlternate) && voiceKeys.isEmpty)
        precondition(prepared == [CGKeyCode(kVK_RightOption)])
        precondition(handle(kVK_RightOption, .flagsChanged))
        precondition(voiceKeys == [CGKeyCode(kVK_RightOption), CGKeyCode(kVK_RightOption)])
        control.setVoiceCapture(false); voiceKeys.removeAll()
        precondition(handle(kVK_Function, .flagsChanged, .maskSecondaryFn))
        precondition(prepared.last == CGKeyCode(kVK_Function)); wait(0.3)
        precondition(voiceKeys == [CGKeyCode(kVK_Function)])
        precondition(handle(kVK_Function, .flagsChanged) && voiceKeys.count == 2)
        control.setVoiceCapture(false); voiceKeys.removeAll()
        precondition(handle(kVK_RightOption, .flagsChanged, .maskAlternate))
        precondition(handle(kVK_ANSI_A, .keyDown, .maskAlternate))
        precondition(handle(kVK_RightOption, .flagsChanged)); wait()
        precondition(voiceKeys.isEmpty && replays.pointee.isEmpty && discarded == 1)
        replays.pointee.removeAll()
        precondition(handle(kVK_Function, .flagsChanged, .maskSecondaryFn))
        precondition(handle(kVK_F1, .keyDown, .maskSecondaryFn))
        precondition(handle(kVK_Function, .flagsChanged)); wait(0.3)
        precondition(voiceKeys.isEmpty && replays.pointee.isEmpty && discarded == 2)
        replays.pointee.removeAll()
        precondition(handle(kVK_Function, .flagsChanged, .maskSecondaryFn))
        precondition(handle(kVK_Function, .flagsChanged)); wait(0.3)
        precondition(voiceKeys.isEmpty && replays.pointee.isEmpty && discarded == 3)
        let preparationCount = prepared.count
        control.setRDPPointer(false)
        precondition(handle(kVK_RightOption, .flagsChanged, .maskAlternate))
        precondition(handle(kVK_RightOption, .flagsChanged) && voiceKeys.isEmpty)
        control.setRDPPointer(true); control.setVoiceEnabled(false)
        precondition(handle(kVK_RightOption, .flagsChanged, .maskAlternate))
        precondition(handle(kVK_RightOption, .flagsChanged))
        precondition(prepared.count == preparationCount)
        print("PASS: native RDP speech prepares before original modifiers, never replays them; chords, other apps and unavailable voice remain native")
        control.setDeleteEnabled(true)
        var deletes = 0; control.onDelete = { deletes += 1 }
        var viewerFocused = true
        control.canDeleteInViewer = { viewerFocused }
        for routed in [false, true] {
            control.confirm(routed ? .windows : .mac); control.setRDPPointer(true)
            for key in [kVK_ANSI_X, kVK_Delete] {
                let mapped = routed || key == kVK_ANSI_X
                precondition(handle(key, .keyDown, .maskCommand) == !mapped)
                precondition(handle(key, .keyUp) == !mapped)
            }
        }
        precondition(deletes == 3)
        control.confirm(.mac); control.setRDPPointer(false); viewerFocused = false
        precondition(handle(kVK_ANSI_X, .keyDown, .maskCommand) && deletes == 3)
        control.setRDPPointer(true)
        precondition(handle(kVK_ANSI_X, .keyDown, .maskCommand) && deletes == 3, "A stale viewer cache must not delete in another app")
        control.setRDPPointer(false); viewerFocused = true
        precondition(!handle(kVK_ANSI_X, .keyDown, .maskCommand) && deletes == 4, "A newly focused DJF viewer must not wait for the pointer cache")
        precondition(!handle(kVK_ANSI_X, .keyUp))
        control.setRDPPointer(true); control.setDeleteEnabled(false)
        precondition(handle(kVK_ANSI_X, .keyDown, .maskCommand) && deletes == 4)
        control.setDeleteEnabled(true); control.setVoiceCapture(true)
        precondition(handle(kVK_ANSI_X, .keyDown, .maskCommand) && deletes == 4)
        control.setVoiceCapture(false)
        for flags in [CGEventFlags.maskControl, [.maskCommand, .maskShift], [.maskCommand, .maskAlternate]] {
            precondition(handle(kVK_ANSI_X, .keyDown, flags) && deletes == 4)
        }
        control.configure(available: false, pid: 0)
        precondition(handle(kVK_ANSI_X, .keyDown, .maskCommand) && deletes == 4)
        control.configure(available: true, pid: getpid())
        print("PASS: Command delete aliases work in routed and unrouted DJF viewers; other apps, unavailable receivers, speech and other chords remain native")

        control.setRDPPointer(true); control.setNativeGestures(true); control.setMacScroll(true)
        control.setPointerGain(10)
        var scrolls = 0; control.onScroll = { _, _, _ in scrolls += 1 }
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0)!
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        precondition(control.handle(proxy: nil, type: .scrollWheel, event: scroll) != nil && scrolls == 0)
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .mouseMoved] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
            event.setIntegerValueField(.mouseEventDeltaX, value: 3)
            precondition(control.handle(proxy: nil, type: type, event: event) != nil)
            precondition(event.getIntegerValueField(.mouseEventDeltaX) == 3 && event.getIntegerValueField(.eventSourceUserData) == 0)
        }
        let gesture = CGEvent(source: nil)!
        precondition(control.handle(proxy: nil, type: CGEventType(rawValue: 29)!, event: gesture) != nil)
        precondition(control.motionSnapshot["samples"] == 0)
        print("PASS: clicking or focusing unrouted RDP leaves native clicks, motion, scrolling and gestures untouched")
    }
}
