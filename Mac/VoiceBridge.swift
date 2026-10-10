import AppKit
import Carbon

/// An app-owned input client for the existing Mac Doubao IME. Only text from
/// this client is sent to Windows; no clipboard or other application's text is read.
@MainActor
final class VoiceBridge: NSObject, NSTextViewDelegate {
    private var panel: NSPanel?
    private var textView: VoiceTextView?
    private var previousSource: TISInputSource?
    private var previousApp: NSRunningApplication?
    private var trigger: UInt16 = 0
    private var clearing = false
    private var ending = false, discard = false
    private var toggleReleased = false
    private var endStarted = Date.distantPast, changedAt = Date.distantPast
    private var timer: Timer?
    private var session = ""
    private var lastSentText = ""
    private var updates = 0, draftUpdates = 0
    var snapshot: [String: Any] {
        ["prepared": panel != nil, "hidden": panel?.alphaValue == 0,
         "inputFocused": panel?.isKeyWindow ?? false, "sessionActive": !session.isEmpty,
         "fieldCharacters": textView?.string.count ?? 0, "updates": updates, "draftUpdates": draftUpdates]
    }
    var onActive: ((Bool) -> Void)?
    var onBegin: ((String) -> Void)?
    var onUpdate: ((String, String) -> Void)?
    var onEnd: ((String) -> Void)?
    var onCancel: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    func handle(_ event: CGEvent) {
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard panel != nil else { return }
        if ending { onActive?(false); return }
        if session.isEmpty { begin(trigger: key) }
        if event.type == .keyDown { finish(); return }
        onStatus?("Mac 豆包正在向专用输入框输出")
        if trigger == kVK_Function && key == kVK_Function && !event.flags.contains(.maskSecondaryFn) {
            finish()
        } else if trigger == kVK_RightOption && key == kVK_RightOption {
            if !event.flags.contains(.maskAlternate) { toggleReleased = true }
            else if toggleReleased { finish() }
        }
    }

    func prepare() -> Bool {
        if panel != nil { return true }
        let sources = TISCreateInputSourceList([kTISPropertyBundleID as String: "com.bytedance.inputmethod.doubaoime"] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first(where: { item in
            guard let value = TISGetInputSourceProperty(item, kTISPropertyInputSourceIsSelectCapable) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
        }) else { onStatus?("Mac 豆包输入法未启用"); return false }
        previousSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        previousApp = NSWorkspace.shared.frontmostApplication
        let left = NSScreen.screens.map { $0.frame.minX }.min() ?? 0
        let panel = SpeechInputPanel(contentRect: NSRect(x: left - 480, y: 0, width: 460, height: 170),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "语音输入通道"
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.alphaValue = 0; panel.isOpaque = false; panel.hasShadow = false
        panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = VoiceTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        view.font = .systemFont(ofSize: 16); view.isRichText = false; view.delegate = self
        view.onCompositionChange = { [weak self] marked in self?.publishText(marked: marked) }
        panel.contentView?.addSubview(view)
        self.panel = panel; textView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        guard TISSelectInputSource(source) == noErr else { close(); onStatus?("无法选择 Mac 豆包输入法"); return false }
        view.inputContext?.activate()
        return true
    }

    private func begin(trigger: UInt16) {
        self.trigger = trigger; ending = false; discard = false; toggleReleased = false
        session = UUID().uuidString; changedAt = .distantPast
        lastSentText = ""; updates = 0; draftUpdates = 0
        onBegin?(session); onActive?(true)
    }

    func textDidChange(_ notification: Notification) {
        publishText(marked: textView?.hasMarkedText() ?? false)
    }

    private func publishText(marked: Bool) {
        guard !clearing, panel != nil else { return }
        if session.isEmpty { begin(trigger: UInt16(kVK_RightOption)) }
        changedAt = Date()
        if !discard {
            let text = textView?.string ?? ""
            guard text != lastSentText else { return }
            lastSentText = text; updates += 1
            if marked { draftUpdates += 1 }
            onUpdate?(session, text)
        }
    }

    private func finish() {
        guard !ending else { return }
        ending = true; endStarted = Date()
        onActive?(false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = self.textView?.string ?? ""
                // Allow the final cloud transcription and text cleanup to settle.
                if (Date().timeIntervalSince(self.endStarted) >= 1.2 && !text.isEmpty && Date().timeIntervalSince(self.changedAt) >= 1.2)
                    || Date().timeIntervalSince(self.endStarted) >= 5 {
                    let session = self.session
                    if !self.discard {
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.onUpdate?(session, text) }
                        self.onEnd?(session)
                    }
                    self.clearSession()
                    self.onStatus?(self.discard ? "语音输入已停止" : (text.isEmpty ? "没有识别到文字" : "Mac 豆包文字已实时输入 Windows"))
                }
            }
        }
    }

    func cancel() {
        guard !session.isEmpty else { return }
        discard = true; onCancel?(session)
        MacVoiceEvents.cancellationEvents(trigger: trigger).forEach(MacVoiceEvents.post)
        clearSession()
        onStatus?("语音输入已停止")
    }

    private func clearSession() {
        timer?.invalidate(); timer = nil
        clearing = true; textView?.unmarkText(); textView?.string = ""; clearing = false
        lastSentText = ""
        session = ""; ending = false; onActive?(false)
    }

    func leave() { cancel(); close() }

    private func close() {
        timer?.invalidate(); timer = nil
        textView?.inputContext?.deactivate()
        textView?.delegate = nil
        textView?.onCompositionChange = nil
        textView?.string = ""
        panel?.orderOut(nil); panel = nil; textView = nil
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { previousApp?.activate(options: []) }
        previousApp = nil
        if let previousSource { TISSelectInputSource(previousSource) }
        previousSource = nil; onActive?(false)
    }
}
