import AppKit
import Carbon

private final class HIDScope: @unchecked Sendable {
    var operation: (() -> Void)?
    var loop: CFRunLoop?
    var tap: CFMachPort?
}

@MainActor
func prepareVoiceFromHID(_ voice: VoiceBridge) async throws -> Bool {
        let scope = HIDScope()
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard event.getIntegerValueField(.keyboardEventKeycode) == kVK_RightOption,
                      event.getIntegerValueField(.eventSourceUnixProcessID) == getpid() else { return Unmanaged.passUnretained(event) }
                if event.flags.contains(.maskAlternate) { Unmanaged<HIDScope>.fromOpaque(context!).takeUnretainedValue().operation?() }
                return nil // Fixture modifiers never reach another app or Doubao.
            }, userInfo: Unmanaged.passUnretained(scope).toOpaque()) else {
            throw NSError(domain: "VoiceHIDChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "HID permission unavailable"])
        }
        scope.tap = tap
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread {
                let loop = CFRunLoopGetCurrent()!
                scope.loop = loop
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, scope.tap!, 0)!
                CFRunLoopAddSource(loop, source, .commonModes)
                continuation.resume(); CFRunLoopRun()
                CFRunLoopRemoveSource(loop, source, .commonModes)
            }.start()
        }
        defer { CFMachPortInvalidate(tap); if let loop = scope.loop { CFRunLoopStop(loop) } }
        let activated = await withCheckedContinuation { continuation in
            scope.operation = {
                let start = ProcessInfo.processInfo.systemUptime
                let ready = voice.prepareFromHID(trigger: UInt16(kVK_RightOption))
                print("HID preparation ms: \((ProcessInfo.processInfo.systemUptime - start) * 1000)"); fflush(stdout)
                continuation.resume(returning: ready)
            }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightOption), keyDown: down)!
                event.type = .flagsChanged; event.flags = down ? .maskAlternate : []
                event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
                event.post(tap: .cghidEventTap)
            }
        }
    return activated
}
