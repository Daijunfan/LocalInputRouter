import AppKit
import Carbon

@main @MainActor enum VoiceFocusChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let originalApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            do { try await run(originalApp: originalApp); app.terminate(nil) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }
        app.run()
    }
    static func run(originalApp: NSRunningApplication?) async throws {
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        defer {
            if !CFEqual(originalSource, TISCopyCurrentKeyboardInputSource().takeRetainedValue()) { TISSelectInputSource(originalSource) }
            originalApp?.activate(options: [])
        }
        let bridge = VoiceBridge()
        defer { bridge.leave() }
        precondition(bridge.prepare(), "Doubao input source is unavailable")
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        precondition(bridge.snapshot["inputFocused"] as? Bool == true)
        let other = SpeechInputPanel(contentRect: NSRect(x: -800, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        other.alphaValue = 0
        other.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        other.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        precondition(bridge.snapshot["inputFocused"] as? Bool == true,
            "An RDP-style focus change must automatically return keyboard focus to the speech field")
        precondition(bridge.prepare())
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        precondition(bridge.snapshot["inputFocused"] as? Bool == true,
            "Reusing the speech panel must recover focus after another window took it")
        let begin = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightOption), keyDown: true)!
        begin.type = .flagsChanged; begin.flags = .maskAlternate
        bridge.handle(begin)
        other.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        precondition(bridge.isActive && bridge.snapshot["inputFocused"] as? Bool == true,
            "An active recording must recover its IME client after the RDP window takes focus")
        let activeView = NSApp.windows.flatMap { $0.contentView?.subviews ?? [] }
            .compactMap { $0 as? VoiceTextView }.first { ($0.delegate as AnyObject?) === bridge }!
        activeView.insertText("焦点检查", replacementRange: NSRange(location: NSNotFound, length: 0))
        let finish = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true)!
        bridge.handle(finish)
        try await Task.sleep(nanoseconds: UInt64(1.5 * 1_000_000_000))
        bridge.leave(); other.orderOut(nil)
        precondition(bridge.snapshot["prepared"] as? Bool == false)
        originalApp?.activate(options: [])
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        let nativeSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard try await prepareVoiceFromHID(bridge) else {
            throw NSError(domain: "VoiceFocusChecks", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "HID preparation failed"])
        }
        let selectedSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let selectedBundle = TISGetInputSourceProperty(selectedSource, kTISPropertyBundleID)!
        precondition(Unmanaged<CFString>.fromOpaque(selectedBundle).takeUnretainedValue() as String == "com.bytedance.inputmethod.doubaoime",
            "The temporary RDP client must receive the existing Doubao IME's text")
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        guard NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            throw NSError(domain: "VoiceFocusChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native speech client did not become the foreground application"])
        }
        let view = NSApp.windows.flatMap { $0.contentView?.subviews ?? [] }
            .compactMap { $0 as? VoiceTextView }.first { ($0.delegate as AnyObject?) === bridge }!
        view.insertText("语音通道检查", replacementRange: NSRange(location: NSNotFound, length: 0))
        other.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        precondition(bridge.isActive && bridge.snapshot["inputFocused"] as? Bool == true,
            "Native RDP speech must recover focus while recognition is active")
        let end = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true)!
        bridge.handle(end)
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        precondition(bridge.isPrepared && bridge.isActive, "Keep the IME client until final recognition settles")
        let settled = Date().addingTimeInterval(5.5)
        while bridge.isPrepared && Date() < settled {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !bridge.isPrepared && !bridge.isActive else {
            throw NSError(domain: "VoiceFocusChecks", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Transient speech did not release its client after final text settled"])
        }
        precondition(CFEqual(nativeSource, TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
        weak var retiringClient: VoiceTextView?
        autoreleasepool {
            precondition(bridge.prepare())
            retiringClient = NSApp.windows.flatMap { $0.contentView?.subviews ?? [] }
                .compactMap { $0 as? VoiceTextView }.first { ($0.delegate as AnyObject?) === bridge }
            bridge.leave(restoreSource: false)
        }
        precondition(retiringClient != nil,
            "The NSTextInputClient must stay alive until deferred deactivation runs")
        precondition(!bridge.isPrepared && !bridge.isActive)
        precondition(bridge.prepare())
        try await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
        precondition(bridge.snapshot["inputFocused"] as? Bool == true,
            "Deferred cleanup must not deactivate a newly prepared speech client")
        bridge.leave(restoreSource: false)
        try await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
        print("PASS: hidden Doubao speech panel automatically regains lost focus and restores its input source on exit")
        print("PASS: recording continues in the same IME client after an RDP-style focus change")
        print("PASS: transient RDP speech waits for final text and releases its IME client")
        print("PASS: transient RDP selects its IME and restores the previous source; the client survives deferred deactivation")
        print("PASS: native RDP speech owns the active application while recording")
    }
}
