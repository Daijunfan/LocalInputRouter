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
        control.canUseNativeViewerShortcuts = { _ in viewerFocused }
        for routed in [false, true] {
            control.confirm(routed ? .windows : .mac); control.setRDPPointer(true)
            precondition(handle(kVK_ANSI_X, .keyDown, .maskCommand), "Letter X keeps standard Cut")
            precondition(handle(kVK_ANSI_X, .keyUp))
            precondition(!handle(kVK_Delete, .keyDown, .maskCommand))
            precondition(!handle(kVK_Delete, .keyUp))
        }
        precondition(deletes == 2)
        control.confirm(.mac); control.setRDPPointer(false); viewerFocused = false
        precondition(handle(kVK_Delete, .keyDown, .maskCommand) && deletes == 2)
        control.setRDPPointer(true)
        precondition(handle(kVK_Delete, .keyDown, .maskCommand) && deletes == 2, "A stale viewer cache must not delete in another app")
        control.setRDPPointer(false); viewerFocused = true
        precondition(!handle(kVK_Delete, .keyDown, .maskCommand) && deletes == 3, "The observed Command+Backspace chord must not wait for the pointer cache")
        precondition(!handle(kVK_Delete, .keyUp))
        control.setRDPPointer(true); control.setDeleteEnabled(false)
        precondition(handle(kVK_Delete, .keyDown, .maskCommand) && deletes == 3)
        control.setDeleteEnabled(true); control.setVoiceCapture(true)
        precondition(handle(kVK_Delete, .keyDown, .maskCommand) && deletes == 3)
        control.setVoiceCapture(false)
        for flags in [CGEventFlags.maskControl, [.maskCommand, .maskShift], [.maskCommand, .maskAlternate]] {
            precondition(handle(kVK_Delete, .keyDown, flags) && deletes == 3)
        }
        control.configure(available: false, pid: 0)
        precondition(!handle(kVK_Delete, .keyDown, .maskCommand) && deletes == 4,
                     "A ready native receiver must not depend on Deskflow's connection")
        precondition(!handle(kVK_Delete, .keyUp))
        control.configure(available: true, pid: getpid())
        print("PASS: Command+Backspace deletes in both modes and during backend recovery; letter X, other apps and voice keep their original meaning")

        control.confirm(.mac); viewerFocused = true
        var screenshots = 0; control.onViewerScreenshot = { screenshots += 1 }
        for key in [kVK_ANSI_1, kVK_ANSI_2] {
            precondition(handle(kVK_Command, .flagsChanged, .maskCommand), "Mac Command-down must never be suppressed")
            precondition(handle(key, .keyDown, .maskCommand), "The system screenshot shortcut must remain local")
            precondition(handle(key, .keyUp, .maskCommand))
            precondition(handle(kVK_Command, .flagsChanged))
        }
        precondition(screenshots == 2)
        precondition(handle(kVK_Command, .flagsChanged, .maskCommand))
        precondition(handle(kVK_ANSI_C, .keyDown, .maskCommand), "Native copy remains available")
        precondition(handle(kVK_ANSI_C, .keyUp, .maskCommand))
        precondition(handle(kVK_Command, .flagsChanged))
        viewerFocused = false
        precondition(handle(kVK_Command, .flagsChanged, .maskCommand), "Other Mac apps retain their original Command events")
        precondition(handle(kVK_Command, .flagsChanged))
        control.confirm(.windows); viewerFocused = true
        precondition(handle(kVK_Command, .flagsChanged, .maskCommand), "Routed shortcuts remain unchanged")
        precondition(handle(kVK_Command, .flagsChanged))
        control.confirm(.mac)
        precondition(screenshots == 2)
        print("PASS: native screenshot chords preserve every Mac Command event and request only a remote menu mask")

        control.setRDPPointer(true); control.setNativeKeysReady(true); control.setNativeRDPKeyboard(true)
        var keys = [(UInt16, Bool, Int)](), modifiers = [Int]()
        control.onNativeKey = { keys.append(($0,$1,$2)) }; control.onNativeModifiers = { modifiers.append($0) }
        precondition(WindowsKeyboard.deskflowModifiers == "modifierSuper=ctrl\nmodifierCtrl=super")
        for (key, flags, expected) in [(kVK_Command,CGEventFlags(rawValue:0x100008),1),
                                      (kVK_RightCommand,CGEventFlags(rawValue:0x100010),2),
                                      (kVK_Control,CGEventFlags(rawValue:0x40001),4),
                                      (kVK_RightControl,CGEventFlags(rawValue:0x42000),8)] {
            precondition(handle(key,.flagsChanged,flags), "Original modifier transitions stay available to macOS")
            precondition(modifiers.last == expected)
            for letter in [kVK_ANSI_C,kVK_ANSI_X,kVK_ANSI_Q,kVK_ANSI_T,kVK_LeftArrow,kVK_F16] {
                precondition(!handle(letter,.keyDown,flags))
                precondition(keys.last!.0 == WindowsKeyboard.keys[UInt16(letter)] && keys.last!.1 && keys.last!.2 == expected)
                precondition(!handle(letter,.keyUp,flags))
                precondition(!keys.last!.1)
            }
            precondition(handle(key,.flagsChanged))
            precondition(modifiers.last == 0)
        }
        let all = CGEventFlags([.maskCommand,.maskControl,.maskShift,.maskAlternate])
        precondition(!handle(kVK_ANSI_C,.keyDown,all) && keys.last!.2 == 85)
        precondition(handle(kVK_Command,.flagsChanged))
        precondition(!handle(kVK_ANSI_C,.keyUp), "A chord key released after its modifier must still be released remotely")
        let count=keys.count
        precondition(handle(kVK_ANSI_A,.keyDown), "Ordinary native RDP Unicode input must stay native")
        precondition(handle(kVK_ANSI_2,.keyDown,.maskCommand) && keys.count == count, "Mac screenshot shortcut must stay local")
        precondition(deletes == 4, "Command+letter X must not invoke Delete")
        viewerFocused=false
        precondition(handle(kVK_ANSI_C,.keyDown,.maskCommand) && keys.count == count)
        viewerFocused=true;control.setVoiceCapture(true)
        precondition(handle(kVK_ANSI_C,.keyDown,.maskCommand) && keys.count == count)
        control.setVoiceCapture(false)
        control.configure(available: false, pid: 0); control.setNativeRDPKeyboard(false)
        precondition(handle(kVK_Command,.flagsChanged,.maskCommand) && modifiers.last == 1)
        precondition(!handle(kVK_ANSI_C,.keyDown,.maskCommand),
                     "The first native chord must work before the focus cache or backend is ready")
        precondition(!handle(kVK_ANSI_C,.keyUp,.maskCommand))
        precondition(handle(kVK_Command,.flagsChanged) && modifiers.last == 0)
        viewerFocused=false
        precondition(handle(kVK_ANSI_C,.keyDown,.maskCommand), "Recovery must not capture another Mac app")
        viewerFocused=true; control.setNativeKeysReady(false)
        precondition(handle(kVK_ANSI_C,.keyDown,.maskCommand), "A disconnected native channel cannot consume input")
        control.configure(available: true, pid: getpid())
        print("PASS: left/right Command and Control fully exchange; all shortcut keys share one projection; screenshot, Unicode, voice and other apps remain native")

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
