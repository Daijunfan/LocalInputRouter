import CoreGraphics
import Carbon

/// Marks a real key as local speech input. The bundled backend adapter returns
/// it unchanged to macOS instead of forwarding it to Windows.
enum MacVoiceEvents {
    static let marker: Int64 = 0x444A46564F494300
    static func owns(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) & ~0xff == marker
    }
    static func local(_ event: CGEvent) -> Unmanaged<CGEvent> {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return Unmanaged.passUnretained(event)
    }
    static func post(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        copy.setIntegerValueField(.eventSourceUserData, value: marker)
        copy.post(tap: .cghidEventTap)
    }

    static func cancellationEvents(trigger: UInt16) -> [CGEvent] {
        if trigger == kVK_Function {
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Function), keyDown: false) else { return [] }
            up.type = .flagsChanged; up.flags = []
            return [up]
        }
        // A one-sided synthetic Escape leaves macOS's key state pressed and
        // suppresses subsequent global speech shortcuts even after Mac return.
        return [true, false].compactMap { pressed in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: pressed)
            event?.flags = []
            return event
        }
    }
}
