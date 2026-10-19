import AppKit
import ApplicationServices
import Carbon

private final class Probe {
    var controls: [Int64] = []
    var leaked = 0
    var motion: [[Int64]] = []
    var mouseEvents: [CGEventType] = []
    var nextMotion: (Int64, Int64) = (0, 0)
    var clickStates: [Int64] = []
}

private final class VoicePathProbe {
    var events: [UInt32] = []
}

/// Check the production HID -> bundled backend -> local guard -> session path.
/// F16 is trapped before it can reach an app; no recording is started.
@MainActor
func runLocalVoicePathCheck() -> [String: Any] {
    let probe = VoicePathProbe()
    let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_F16)
                && event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                Unmanaged<VoicePathProbe>.fromOpaque(info!).takeUnretainedValue().events.append(type.rawValue)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(probe).toOpaque()),
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        return ["pass": false, "error": "Could not observe the local session path"]
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    defer {
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_F16), keyDown: down)!
        event.flags = []
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        _ = MacVoiceEvents.local(event)
        event.post(tap: .cghidEventTap)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    return ["pass": probe.events == [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue],
            "events": probe.events]
}

/// Uses real Quartz taps. Synthetic test events are trapped before applications.
/// No real keystrokes, screen contents or user input are recorded.
@MainActor
func runInputChecks(custom: Bool = false) -> Int32 {
    // Match production capture: associated cursors let WindowServer rewrite
    // synthetic deltas from absolute locations, making this test dependent on
    // the current pointer position and display edge.
    CGAssociateMouseAndMouseCursorPosition(0)
    defer { CGAssociateMouseAndMouseCursorPosition(1) }
    let toggle = custom ? RouterShortcut(keyCode: UInt16(kVK_F8), modifiers: CGEventFlags([.maskControl, .maskShift]).rawValue) : .toggle
    let emergency = custom ? RouterShortcut(keyCode: UInt16(kVK_F7), modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue) : .emergency
    let testMarker: Int64 = 0x444A4654455354
    let probe = Probe()
    var taps: [CFMachPort] = []
    var sources: [CFRunLoopSource] = []
    func attach(_ location: CGEventTapLocation, _ callback: @escaping CGEventTapCallBack) -> Bool {
        guard let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask.max, callback: callback,
            userInfo: Unmanaged.passUnretained(probe).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        taps.append(tap); sources.append(source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }
    guard attach(.cgSessionEventTap, { _, _, event, info in
        if event.getIntegerValueField(.eventSourceUserData) == 0x444A4654455354 {
            Unmanaged<Probe>.fromOpaque(info!).takeUnretainedValue().leaked += 1
            return nil
        }
        return Unmanaged.passUnretained(event)
    }), attach(.cghidEventTap, { _, type, event, info in
        let probe = Unmanaged<Probe>.fromOpaque(info!).takeUnretainedValue()
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if [InputControl.dragMarker, InputControl.releaseMarker, InputControl.rdpPointerMarker].contains(marker) {
            probe.mouseEvents.append(type)
            if type == .leftMouseDown { probe.clickStates.append(event.getIntegerValueField(.mouseEventClickState)) }
            return nil
        }
        if event.getIntegerValueField(.eventSourceUserData) == 0x444A4654455354,
            [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .leftMouseUp].contains(type) {
            probe.mouseEvents.append(type)
            if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
                probe.motion.append([
                event.getIntegerValueField(.mouseEventDeltaX), event.getIntegerValueField(.mouseEventDeltaY)])
            }
            return nil
        }
        if event.getIntegerValueField(.eventSourceUserData) == InputControl.marker {
            if type == .keyDown {
                Unmanaged<Probe>.fromOpaque(info!).takeUnretainedValue().controls.append(event.getIntegerValueField(.keyboardEventKeycode))
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }) else { print("BLOCKED: native Quartz capture permission is unavailable"); return 2 }
    let control = InputControl()
    control.onRequest = { destination in
        if destination == .windows { control.select(destination) }
    }
    control.setShortcuts(toggle: toggle, emergency: emergency)
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
    do { try sleeper.run() } catch { print("FAIL: could not start recovery test process"); return 1 }
    defer {
        control.reset(); control.remove()
        if sleeper.isRunning { sleeper.terminate() }
        for tap in taps { CFMachPortInvalidate(tap) }
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
    control.configure(available: true, pid: sleeper.processIdentifier)
    guard control.install() else { print("BLOCKED: routing control tap could not be installed"); return 2 }
    // WindowServer can rewrite posted synthetic motion when another app
    // re-associates its cursor. Restore fixture deltas immediately before the
    // real production tap; physical events are never changed.
    guard attach(.cghidEventTap, { _, type, event, info in
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let pointer = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type)
        if pointer && ![Int64(0x444A4654455354), InputControl.dragMarker, InputControl.releaseMarker, InputControl.rdpPointerMarker].contains(tag) {
            return nil // Physical motion must not consume the fixture's fractional gain or drag state.
        }
        if event.getIntegerValueField(.eventSourceUserData) == 0x444A4654455354,
           [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
            let delta = Unmanaged<Probe>.fromOpaque(info!).takeUnretainedValue().nextMotion
            event.setIntegerValueField(.mouseEventDeltaX, value: delta.0)
            event.setIntegerValueField(.mouseEventDeltaY, value: delta.1)
        }
        return Unmanaged.passUnretained(event)
    }) else { return 2 }
    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [.maskControl, .maskAlternate], repeatKey: Bool = false) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: testMarker)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
    key(toggle.keyCode, down: true, flags: CGEventFlags(rawValue: toggle.modifiers)); settle()
    // Holding the shortcut must not oscillate between machines.
    key(toggle.keyCode, down: true, flags: CGEventFlags(rawValue: toggle.modifiers), repeatKey: true)
    key(toggle.keyCode, down: false, flags: [])
    if custom {
        key(CGKeyCode(kVK_Space), down: true)
        key(CGKeyCode(kVK_Space), down: false, flags: [])
    }
    // Unhandled input must still be blocked by the final local guard.
    key(CGKeyCode(kVK_F17), down: true, flags: [])
    key(CGKeyCode(kVK_F17), down: false, flags: [])
    let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
    scroll.setIntegerValueField(.eventSourceUserData, value: testMarker)
    scroll.post(tap: .cghidEventTap)
    settle()
    guard probe.controls == [Int64(kVK_F18)] && probe.leaked == 0 else {
        print("FAIL: toggle priority, repeat suppression or local-input guard: \(probe.controls), leaks=\(probe.leaked)")
        return 1
    }
    control.confirm(.windows)
    func motion(_ dx: Int64, _ dy: Int64, type: CGEventType = .mouseMoved) {
        CGAssociateMouseAndMouseCursorPosition(0)
        probe.nextMotion = (dx, dy)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 500, y: 500), mouseButton: .left)!
        event.setIntegerValueField(.eventSourceUserData, value: testMarker)
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        event.post(tap: .cghidEventTap)
        settle()
    }
    control.setPointerGain(0.5)
    for _ in 0..<4 { motion(1, -1) }
    guard probe.motion == [[0,0], [1,-1], [0,0], [1,-1]] else {
        print("FAIL: decimal motion gain / fractional carry: \(probe.motion)"); return 1
    }
    probe.motion = []; control.setPointerGain(10)
    motion(-100, 100, type: .leftMouseDragged)
    guard probe.motion == [[-1000,1000]] else { print("FAIL: drag / maximum gain"); return 1 }
    probe.motion = []; control.confirm(.mac)
    motion(3, -2)
    guard probe.motion == [[3,-2]] else { print("FAIL: gain changed local Mac movement"); return 1 }
    control.confirm(.windows)
    print("PASS: 0.5x fractional motion, 10x dragging, and unchanged Mac input")
    control.setPointerGain(1)
    func click(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 500, y: 500), mouseButton: .left)!
        event.setIntegerValueField(.eventSourceUserData, value: testMarker)
        event.post(tap: .cghidEventTap)
        settle()
    }
    for delayedClick in [false, true] {
        control.confirm(.windows); probe.mouseEvents = []
        control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: 10)
        if !delayedClick { click(.leftMouseDown); click(.leftMouseUp) }
        control.setTouchFrame(count: 0, x: 0, y: 0, time: 10.1)
        control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: 10.2)
        if delayedClick { click(.leftMouseDown); click(.leftMouseUp) }
        motion(13, 0); motion(4, 3)
        // Native tap clicks during a held synthetic drag must not release it.
        click(.leftMouseDown); click(.leftMouseUp)
        control.setTouchFrame(count: 0, x: 0, y: 0, time: 10.8); settle()
        guard probe.mouseEvents == [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp] else {
            print("FAIL: double-tap drag / delayed native click=\(delayedClick): \(probe.mouseEvents.map(\.rawValue)), \(control.motionSnapshot)"); return 1
        }
        // The next ordinary contact must move freely after release.
        control.setTouchFrame(count: 1, x: 0.6, y: 0.5, time: 11)
        motion(20, 0)
        guard probe.mouseEvents.last == .mouseMoved else { print("FAIL: drag stuck after lift"); return 1 }
    }
    guard control.motionSnapshot["dragStarts"] == 2 && control.motionSnapshot["dragReleases"] == 2 else {
        print("FAIL: double-tap drag press/release balance"); return 1
    }
    print("PASS: double-tap drag through real HID taps, delayed native click, exactly one release and free movement after lift")
    control.confirm(.windows); control.setRDPPointer(true); probe.mouseEvents = []; probe.clickStates = []
    control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: 20)
    control.setTouchFrame(count: 0, x: 0, y: 0, time: 20.1)
    control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: 20.2)
    motion(13, 0); motion(4, 3)
    control.setTouchFrame(count: 0, x: 0, y: 0, time: 20.8); settle()
    guard probe.mouseEvents == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp],
          probe.clickStates == [1] else {
        print("FAIL: native RDP drag button metadata: \(probe.mouseEvents.map(\.rawValue)), \(probe.clickStates)"); return 1
    }
    print("PASS: native RDP drag uses a real click count and releases the held button")
    control.confirm(.mac); probe.mouseEvents = []; probe.clickStates = []
    control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: 30)
    control.setTouchFrame(count: 0, x: 0, y: 0, time: 30.1)
    control.setTouchFrame(count: 1, x: 0.5, y: 0.5, time: 30.2)
    motion(13, 0); motion(4, 0)
    control.setTouchFrame(count: 0, x: 0, y: 0, time: 30.4); settle()
    guard probe.mouseEvents == [.mouseMoved, .mouseMoved], probe.clickStates.isEmpty else {
        print("FAIL: focusing native RDP intercepted unrouted Mac input"); return 1
    }
    control.confirm(.windows); control.setRDPPointer(false)
    print("PASS: focusing native RDP leaves unrouted pointer and touch input unchanged")
    key(toggle.keyCode, down: true, flags: CGEventFlags(rawValue: toggle.modifiers))
    key(toggle.keyCode, down: false, flags: [])
    settle()
    guard probe.controls == [Int64(kVK_F18), Int64(kVK_F19)] && probe.leaked == 0 else {
        print("FAIL: reverse toggle/key release was not intercepted"); return 1
    }
    key(emergency.keyCode, down: true, flags: CGEventFlags(rawValue: emergency.modifiers))
    key(emergency.keyCode, down: false, flags: [])
    settle()
    guard !sleeper.isRunning && sleeper.terminationStatus == SIGKILL && probe.leaked == 0 else {
        print("FAIL: emergency recovery did not terminate the stuck backend"); return 1
    }
    control.confirm(.mac)
    let normal = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true)!
    guard control.guardLocal(normal) != nil else { print("FAIL: Mac input was not restored"); return 1 }

    let escapeSleeper = Process()
    escapeSleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); escapeSleeper.arguments = ["30"]
    do { try escapeSleeper.run() } catch { print("FAIL: triple-Esc test process could not start"); return 1 }
    defer { if escapeSleeper.isRunning { escapeSleeper.terminate() } }
    control.configure(available: true, pid: escapeSleeper.processIdentifier)
    control.confirm(.windows)
    func escapeTap() {
        key(CGKeyCode(kVK_Escape), down: true, flags: [])
        key(CGKeyCode(kVK_Escape), down: false, flags: [])
        settle()
    }
    // A held Esc is one press, not a triple press.
    key(CGKeyCode(kVK_Escape), down: true, flags: [])
    key(CGKeyCode(kVK_Escape), down: true, flags: [], repeatKey: true)
    key(CGKeyCode(kVK_Escape), down: true, flags: [], repeatKey: true)
    key(CGKeyCode(kVK_Escape), down: false, flags: [])
    settle()
    guard escapeSleeper.isRunning else { print("FAIL: held Esc triggered recovery"); return 1 }
    // Slow presses must not accumulate into an emergency.
    RunLoop.current.run(until: Date().addingTimeInterval(1.6))
    escapeTap(); escapeTap()
    guard escapeSleeper.isRunning else { print("FAIL: slow Esc presses triggered recovery"); return 1 }
    // Another key breaks the sequence.
    key(CGKeyCode(kVK_F17), down: true, flags: [])
    key(CGKeyCode(kVK_F17), down: false, flags: [])
    escapeTap(); escapeTap()
    guard escapeSleeper.isRunning else { print("FAIL: interrupted Esc sequence triggered recovery"); return 1 }
    escapeTap()
    guard !escapeSleeper.isRunning && escapeSleeper.terminationStatus == SIGKILL && probe.leaked == 0 else {
        print("FAIL: triple Esc did not recover without leaking local input"); return 1
    }
    guard control.guardLocal(normal) != nil else { print("FAIL: triple Esc did not restore Mac input"); return 1 }
    print("PASS: triple Esc recovery, hold/timeout/interruption handling, and Mac restoration")
    print("PASS: native HID priority, forward/back toggle, key-up suppression, held-key repeat, keyboard/scroll local guard, emergency SIGKILL, Mac input restoration")
    return 0
}
