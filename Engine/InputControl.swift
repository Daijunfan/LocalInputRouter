import Foundation
import CoreGraphics
import Carbon
import Darwin

enum InputDestination: String, Sendable { case mac, windows }

/// Fixed gain with fractional carry: no extra acceleration or cursor inertia.
struct PointerGain {
    private var hundredths: Int64 = 100
    private var rx: Int64 = 0, ry: Int64 = 0
    var factor: Double {
        get { Double(hundredths) / 100 }
        set { hundredths = Int64((newValue * 100).rounded()); reset() }
    }
    init(factor: Double = 1) { self.factor = factor }
    mutating func reset() { rx = 0; ry = 0 }
    mutating func scale(_ dx: Int64, _ dy: Int64) -> (Int64, Int64) {
        let x = dx * hundredths + rx, y = dy * hundredths + ry
        rx = x % 100; ry = y % 100
        return (x / 100, y / 100)
    }
}

/// Remote-only drag state. macOS can keep sending dragged events after a
/// tap-drag finger lifts; those become ordinary motion until its button-up.
struct TouchDragRelease {
    private(set) var contacts = 0
    private(set) var dragging = false
    private(set) var released = false
    mutating func contactCount(_ value: Int) -> Bool {
        contacts = value
        if value == 0 && dragging { dragging = false; released = true; return true }
        return false
    }
    mutating func observe(_ type: CGEventType) -> CGEventType {
        if type == .leftMouseDown { dragging = false; released = false }
        if type == .leftMouseUp { dragging = false; released = false }
        if type == .leftMouseDragged {
            if released { return .mouseMoved }
            if contacts > 0 { dragging = true }
        }
        return type
    }
    mutating func reset() { self = TouchDragRelease() }
}

/// Installed after Deskflow's HID tap, at the head of the same event stream.
/// Control shortcuts and remote pointer gain run before Deskflow forwards IO.
final class InputControl: @unchecked Sendable {
    static let marker: Int64 = 0x444A46524F555445
    static let releaseMarker: Int64 = 0x444A465550
    static let dragMarker: Int64 = 0x444A4644524147
    static let rdpPointerMarker: Int64 = 0x444A4652445050
    private let lock = NSLock()
    private var target = InputDestination.mac
    private var confirmed = InputDestination.mac
    private var available = false
    private var enginePID: pid_t = 0
    private var swallowed = Set<CGKeyCode>()
    private var toggleShortcut = RouterShortcut.toggle
    private var emergencyShortcut = RouterShortcut.emergency
    private var escapePressCount = 0
    private var escapeSequenceStarted: UInt64 = 0
    private var escapeIsDown = false
    private var pointerGain = 1.0
    private var gain = PointerGain()
    private var nativeGestures = false
    private var macScroll = false
    private var scrollGain = 1.5
    private var voiceCapture = false
    private var rdpPointer = false
    private var voiceEnabled = false
    private var deleteEnabled = false
    private var pendingVoiceKey: CGKeyCode?
    private var pendingVoiceEvent: CGEvent?
    private var voiceGeneration = 0
    private var optionRelayed = false
    private var lastRecovery = ""
    private var contacts = 0
    private var tapReserved = false
    private var drag = TouchDragRelease()
    private var tapDrag = TapDrag()
    private var nativeLeftDown = false
    private var dragStarts: Int64 = 0
    private var lastPointer = CGPoint.zero
    private var dragReleases: Int64 = 0
    private var motionSamples: Int64 = 0
    private var motionX: Int64 = 0
    private var motionY: Int64 = 0
    private var tap: CFMachPort?
    private var guardTap: CFMachPort?
    private var loop: CFRunLoop?
    var onRequest: ((InputDestination) -> Void)?
    var onEmergency: (() -> Void)?
    var onRecoverCursor: (() -> Void)?
    var onScroll: ((Double, Double, Bool) -> Void)?
    var onVoiceEvent: ((CGEvent) -> Void)?
    var onVoiceCancel: (() -> Void)?
    var onVoicePrepare: ((CGKeyCode) -> Bool)?
    var onVoiceDiscard: (() -> Void)?
    var onDelete: (() -> Void)?
    var isInstalled: Bool { tap != nil && guardTap != nil }
    var recoveryReason: String {
        lock.lock(); defer { lock.unlock() }; return lastRecovery
    }

    func setPointerGain(_ value: Double) {
        lock.lock()
        pointerGain = value; gain.factor = value; gain.reset()
        motionSamples = 0; motionX = 0; motionY = 0
        lock.unlock()
    }

    var motionSnapshot: [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        return ["samples": motionSamples, "dx": motionX, "dy": motionY, "dragStarts": dragStarts, "dragReleases": dragReleases]
    }

    func setShortcuts(toggle: RouterShortcut, emergency: RouterShortcut) {
        lock.lock(); toggleShortcut = toggle; emergencyShortcut = emergency; lock.unlock()
    }

    func setNativeGestures(_ enabled: Bool) {
        lock.lock(); nativeGestures = enabled; if !enabled { contacts = 0 }; lock.unlock()
    }
    func setMacScroll(_ enabled: Bool) { lock.lock(); macScroll = enabled; lock.unlock() }
    func setTapReservation(_ enabled: Bool) { lock.lock(); tapReserved = enabled; lock.unlock() }
    func setScrollGain(_ value: Double) { lock.lock(); scrollGain = value; lock.unlock() }
    func setDragTapInterval(_ value: Double) { lock.lock(); tapDrag.tapInterval = value; lock.unlock() }
    func setVoiceCapture(_ value: Bool) { lock.lock(); voiceCapture = value; lock.unlock() }
    func setDeleteEnabled(_ value: Bool) { lock.lock(); deleteEnabled = value; lock.unlock() }
    func setRDPPointer(_ value: Bool) { lock.lock(); rdpPointer = value; gain.reset(); lock.unlock() }
    func setVoiceEnabled(_ value: Bool) {
        lock.lock(); voiceEnabled = value
        if !value { pendingVoiceKey = nil; pendingVoiceEvent = nil; voiceGeneration += 1 }
        if !value { optionRelayed = false }
        lock.unlock()
    }
    func setContactCount(_ value: Int) {
        lock.lock()
        contacts = value
        let release = available && confirmed == .windows && drag.contactCount(value)
        let point = lastPointer
        if release { dragReleases += 1; nativeLeftDown = false }
        lock.unlock()
        if release {
            let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: Self.releaseMarker)
            event?.post(tap: .cghidEventTap)
        }
    }
    func setTouchFrame(count: Int, x: Double, y: Double, time: Double) {
        lock.lock()
        let remote = available && confirmed == .windows
        let release = remote && tapDrag.contact(count: count, x: x, y: y, time: time)
        let point = lastPointer
        if release { dragReleases += 1; nativeLeftDown = false }
        lock.unlock()
        if release { Self.mouse(.leftMouseUp, at: point)?.post(tap: .cghidEventTap) }
        setContactCount(count)
    }
    private static func mouse(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: dragMarker)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }

    func configure(available: Bool, pid: pid_t) {
        lock.lock()
        self.available = available; self.enginePID = pid
        lock.unlock()
    }

    func confirm(_ destination: InputDestination) {
        lock.lock()
        target = destination; confirmed = destination; gain.reset()
        drag.reset()
        tapDrag.reset()
        nativeLeftDown = false; optionRelayed = false
        voiceCapture = false
        pendingVoiceKey = nil; pendingVoiceEvent = nil; voiceGeneration += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        target = .mac; confirmed = .mac; available = false; enginePID = 0
        escapePressCount = 0
        drag.reset()
        tapDrag.reset()
        nativeLeftDown = false; optionRelayed = false
        voiceCapture = false
        pendingVoiceKey = nil; pendingVoiceEvent = nil; voiceGeneration += 1
        lock.unlock()
    }

    func select(_ destination: InputDestination) {
        if destination == .mac { releaseDrag() }
        lock.lock(); target = destination; lock.unlock()
        Self.send(destination)
    }

    private func releaseDrag(proxy: CGEventTapProxy? = nil) {
        lock.lock()
        let held = available && confirmed == .windows && (nativeLeftDown || tapDrag.dragging || drag.dragging)
        let point = lastPointer
        if held { tapDrag.reset(); drag.reset(); nativeLeftDown = false; dragReleases += 1 }
        lock.unlock()
        if held, let event = Self.mouse(.leftMouseUp, at: point) {
            if let proxy { event.tapPostEvent(proxy) } else { event.post(tap: .cghidEventTap) }
        }
    }

    @discardableResult
    func install() -> Bool {
        remove()
        guard let tail = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask.max, callback: { _, type, event, info in
                let control = Unmanaged<InputControl>.fromOpaque(info!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    control.emergency(reason: "macOS 关闭了本地输入钩子")
                    if let tap = control.guardTap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
                return control.guardLocal(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guardTap = tail
        let mask = CGEventMask.max
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, info in
                let control = Unmanaged<InputControl>.fromOpaque(info!).takeUnretainedValue()
                return control.handle(proxy: proxy, type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { remove(); return false }
        tap = port
        let ready = DispatchSemaphore(value: 0)
        Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
            let tailSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tail, 0)!
            lock.lock(); loop = runLoop; lock.unlock()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopAddSource(runLoop, tailSource, .commonModes)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopRemoveSource(runLoop, tailSource, .commonModes)
        }.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        CGEvent.tapEnable(tap: tail, enable: true)
        return true
    }

    func remove() {
        if let tap { CFMachPortInvalidate(tap) }
        if let guardTap { CFMachPortInvalidate(guardTap) }
        tap = nil
        guardTap = nil
        lock.lock(); let oldLoop = loop; loop = nil; lock.unlock()
        if let oldLoop { CFRunLoopStop(oldLoop) }
    }

    func emergency(reason: String = "紧急返回") {
        lock.lock()
        lastRecovery = reason
        let pid = enginePID
        enginePID = 0; available = false; target = .mac; confirmed = .mac
        escapePressCount = 0
        drag.reset()
        tapDrag.reset()
        nativeLeftDown = false; optionRelayed = false
        voiceCapture = false
        pendingVoiceKey = nil; pendingVoiceEvent = nil; voiceGeneration += 1
        lock.unlock()
        // The recovery shortcut must work even if the backend or UI is stuck.
        if pid > 0 { kill(pid, SIGKILL) }
        onRecoverCursor?()
        CGAssociateMouseAndMouseCursorPosition(1)
        DispatchQueue.main.async { [weak self] in self?.onEmergency?() }
    }

    /// Anything Deskflow leaves in the stream must not reach local apps while
    /// routing to Windows, including unsupported system/gesture events.
    func guardLocal(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if MacVoiceEvents.owns(event) {
            event.setIntegerValueField(.eventSourceUserData, value: 0)
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let block = available && (target == .windows || confirmed == .windows)
        let pointer = block && rdpPointer && event.getIntegerValueField(.eventSourceUserData) == Self.rdpPointerMarker
        lock.unlock()
        if pointer { event.setIntegerValueField(.eventSourceUserData, value: 0); return Unmanaged.passUnretained(event) }
        return block ? nil : Unmanaged.passUnretained(event)
    }

    static func send(_ destination: InputDestination, proxy: CGEventTapProxy? = nil) {
        let key = CGKeyCode(destination == .windows ? kVK_F18 : kVK_F19)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            if let proxy { event.tapPostEvent(proxy) } else { event.post(tap: .cghidEventTap) }
        }
    }

    func handle(proxy: CGEventTapProxy?, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emergency(reason: "macOS 关闭了转发输入钩子")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        if MacVoiceEvents.owns(event) { return Unmanaged.passUnretained(event) }
        lock.lock()
        let remote = available && confirmed == .windows
        let rdp = remote && rdpPointer
        let native = remote && nativeGestures
        let forwardScroll = native && macScroll
        let scrollFactor = scrollGain
        let voice = voiceCapture
        let canVoice = voiceEnabled
        let nativeSpeech = available && !remote && rdpPointer && canVoice
        let speechTarget = remote || nativeSpeech
        let multipleContacts = contacts >= 2
        let reserveTap = tapReserved
        if [Self.releaseMarker, Self.dragMarker].contains(event.getIntegerValueField(.eventSourceUserData)) {
            // Never let a delayed forced release touch a local Mac app.
            lock.unlock()
            if rdp { event.setIntegerValueField(.eventSourceUserData, value: Self.rdpPointerMarker) }
            return remote ? Unmanaged.passUnretained(event) : nil
        }
        if remote && [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(type) {
            lastPointer = event.location
            if tapDrag.dragging && (type == .leftMouseDown || type == .leftMouseUp) { lock.unlock(); return nil }
            if type == .leftMouseDown { nativeLeftDown = true; tapDrag.nativePress() }
            if type == .leftMouseUp { nativeLeftDown = false }
            if !tapDrag.dragging { event.type = drag.observe(type) }
        }
        lock.unlock()
        let voiceKey = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // Fn+F-keys and Right Option chords retain their normal Windows use.
        if speechTarget && !voice && (type == .keyDown || (type == .flagsChanged && voiceKey != kVK_Function && voiceKey != kVK_RightOption)) {
            lock.lock()
            let pending: CGEvent? = pendingVoiceKey == CGKeyCode(kVK_RightOption) ? pendingVoiceEvent : nil
            let hadPending = pendingVoiceKey != nil
            if pending != nil { optionRelayed = true }
            pendingVoiceKey = nil; pendingVoiceEvent = nil; voiceGeneration += 1
            lock.unlock()
            if nativeSpeech && hadPending { onVoiceDiscard?() }
            if remote && hadPending, let copy = event.copy(), let proxy {
                _ = MacVoiceEvents.local(copy); copy.tapPostEvent(proxy)
            }
            if remote, let pending {
                if let proxy { pending.tapPostEvent(proxy) } else { pending.post(tap: .cghidEventTap) }
            }
        }
        if speechTarget && canVoice && type == .flagsChanged {
            if voiceKey == kVK_RightOption && !event.flags.contains(.maskAlternate) {
                lock.lock(); let relayed = optionRelayed; optionRelayed = false; lock.unlock()
                if remote && relayed, let copy = event.copy(), let proxy { copy.tapPostEvent(proxy); return MacVoiceEvents.local(event) }
            }
            let alone = event.flags.intersection(RouterShortcut.modifierMask)
            let trigger = (voiceKey == kVK_Function && event.flags.contains(.maskSecondaryFn) && alone.isEmpty)
                || (voiceKey == kVK_RightOption && alone == .maskAlternate)
            if trigger && !voice {
                if nativeSpeech && onVoicePrepare?(voiceKey) != true { return Unmanaged.passUnretained(event) }
                lock.lock(); pendingVoiceKey = voiceKey; pendingVoiceEvent = event.copy(); voiceGeneration += 1
                let generation = voiceGeneration
                lock.unlock()
                if voiceKey == kVK_Function {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self else { return }; self.lock.lock()
                        guard self.voiceGeneration == generation, self.available, self.confirmed == .windows || self.rdpPointer,
                              let copy = self.pendingVoiceEvent else { self.lock.unlock(); return }
                        self.pendingVoiceKey = nil; self.pendingVoiceEvent = nil; self.voiceCapture = true
                        self.lock.unlock(); self.onVoiceEvent?(copy)
                    }
                }
                return MacVoiceEvents.local(event)
            }
            lock.lock()
            if pendingVoiceKey == voiceKey {
                let down = pendingVoiceEvent; pendingVoiceKey = nil; pendingVoiceEvent = nil; voiceGeneration += 1
                let tap = voiceKey == kVK_RightOption
                if tap { voiceCapture = true }
                lock.unlock()
                if tap { if let down { onVoiceEvent?(down) }; if let copy = event.copy() { onVoiceEvent?(copy) } }
                if nativeSpeech && !tap { onVoiceDiscard?() }
                return MacVoiceEvents.local(event)
            }
            lock.unlock()
            if voice {
                lock.lock(); voiceCapture = true; lock.unlock()
                if let copy = event.copy() { onVoiceEvent?(copy) }
                return MacVoiceEvents.local(event)
            }
            if voiceKey == kVK_Function { return MacVoiceEvents.local(event) }
        }
        if speechTarget && voice && [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type) { onVoiceCancel?() }
        // Recognized gestures must not trigger Mission Control or zoom on the Mac.
        if (remote && [18, 29, 30, 31, 32].contains(type.rawValue))
            || (reserveTap && [29, 30, 31, 32].contains(type.rawValue)) { return nil }
        if native && type == .scrollWheel && event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            if forwardScroll {
                let x = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) * scrollFactor
                let y = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) * scrollFactor
                let begin = event.getIntegerValueField(.scrollWheelEventScrollPhase) & 1 != 0
                onScroll?(x, y, begin)
            }
            return nil
        }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
            if native && multipleContacts { return nil }
            lock.lock()
            var startDrag = false
            var alreadyPressed = false
            if remote {
                let rawX = event.getIntegerValueField(.mouseEventDeltaX), rawY = event.getIntegerValueField(.mouseEventDeltaY)
                let (dx, dy) = rdp ? (rawX, rawY) : gain.scale(rawX, rawY)
                event.setIntegerValueField(.mouseEventDeltaX, value: dx)
                event.setIntegerValueField(.mouseEventDeltaY, value: dy)
                motionSamples += 1; motionX += dx; motionY += dy
                lastPointer = event.location
                startDrag = tapDrag.move(dx: dx, dy: dy)
                if startDrag {
                    dragStarts += 1; alreadyPressed = nativeLeftDown
                    drag.reset(); _ = drag.contactCount(contacts)
                }
                if tapDrag.dragging && !startDrag { event.type = .leftMouseDragged }
            }
            lock.unlock()
            if rdp { event.setIntegerValueField(.eventSourceUserData, value: Self.rdpPointerMarker) }
            if startDrag, let proxy {
                if alreadyPressed { event.type = .leftMouseDragged; return Unmanaged.passUnretained(event) }
                // Deskflow sees movement first, then the held button. This
                // avoids interpreting the title-bar gesture as double-click maximize.
                event.type = .mouseMoved; event.tapPostEvent(proxy)
                if let down = Self.mouse(.leftMouseDown, at: event.location) {
                    if rdp { down.setIntegerValueField(.eventSourceUserData, value: Self.rdpPointerMarker) }
                    down.tapPostEvent(proxy)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if rdp && [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type) {
            event.setIntegerValueField(.eventSourceUserData, value: Self.rdpPointerMarker)
            return Unmanaged.passUnretained(event)
        }
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        lock.lock()
        if type == .keyUp && key == kVK_Escape { escapeIsDown = false }
        if type == .keyUp, swallowed.remove(key) != nil {
            lock.unlock(); return nil
        }
        if type == .keyDown {
            if key == kVK_Escape {
                if !escapeIsDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    escapeIsDown = true
                    let now = event.timestamp
                    if escapePressCount == 0 || now < escapeSequenceStarted || now - escapeSequenceStarted > 1_500_000_000 {
                        escapePressCount = 1; escapeSequenceStarted = now
                    } else { escapePressCount += 1 }
                    if escapePressCount == 3 {
                        swallowed.insert(key)
                        lock.unlock()
                        emergency()
                        return nil
                    }
                }
            } else { escapePressCount = 0 }
        }
        let toggle = toggleShortcut.matches(key, flags: event.flags)
        let escape = emergencyShortcut.matches(key, flags: event.flags)
        guard type == .keyDown && (toggle || escape) else {
            let routeVoice = speechTarget && voiceCapture && (type == .keyDown || type == .keyUp)
            let delete = remote && deleteEnabled && !voiceCapture && type == .keyDown
                && event.flags.intersection(RouterShortcut.modifierMask) == .maskCommand
                && (key == kVK_ANSI_X || key == kVK_Delete)
            if delete { swallowed.insert(key) }
            lock.unlock()
            if routeVoice { if let copy = event.copy() { onVoiceEvent?(copy) }; return MacVoiceEvents.local(event) }
            if delete { onDelete?(); return nil }
            return Unmanaged.passUnretained(event)
        }
        if swallowed.contains(key) || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            lock.unlock(); return nil
        }
        swallowed.insert(key)
        let next: InputDestination = target == .mac ? .windows : .mac
        let canSend = available && enginePID > 0
        if toggle && canSend { target = next }
        lock.unlock()
        if escape { emergency() }
        else {
            if canSend && next == .mac { releaseDrag(proxy: proxy); Self.send(next, proxy: proxy) }
            DispatchQueue.main.async { [weak self] in self?.onRequest?(next) }
        }
        return nil
    }
}
