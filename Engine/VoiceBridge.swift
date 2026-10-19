import AppKit
import Carbon

/// An app-owned input client for the existing Mac Doubao IME. Only text from
/// this client is sent to Windows; no clipboard or other application's text is read.
@MainActor
final class VoiceBridge: NSObject, NSTextViewDelegate {
    private var panel: NSPanel?
    private var focusObserver: NSObjectProtocol?
    private var pointerMonitor: Any?
    private var textView: VoiceTextView?
    private var previousSource: TISInputSource?
    private var previousApp: NSRunningApplication?
    private var trigger = UInt16(kVK_RightOption)
    private var clearing = false
    private var ending = false, discard = false
    private var toggleReleased = false
    private var endStarted = Date.distantPast, changedAt = Date.distantPast
    private var timer: Timer?
    private var session = ""
    private var lastSentText = ""
    private var updates = 0, draftUpdates = 0
    private var closeOnIdle = false
    var isPrepared: Bool { panel != nil }
    var isTransient: Bool { panel != nil && closeOnIdle }
    var isActive: Bool { !session.isEmpty }
    var snapshot: [String: Any] {
        ["prepared": panel != nil, "hidden": panel?.alphaValue == 0,
         "inputFocused": panel?.isKeyWindow ?? false, "sessionActive": !session.isEmpty,
         "onActiveSpace": panel?.isOnActiveSpace ?? false,
         "fieldCharacters": textView?.string.count ?? 0, "updates": updates, "draftUpdates": draftUpdates]
    }
    var onActive: ((Bool) -> Void)?
    var onBegin: ((String) -> Void)?
    var onUpdate: ((String, String) -> Void)?
    var onEnd: ((String) -> Void)?
    var onCancel: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    // The HID worker may wait; AppKit's main loop must keep running so the
    // asynchronous activation finishes before Doubao receives the real key.
    nonisolated func prepareFromHID(trigger: UInt16) -> Bool {
        let prepared = DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.prepare(transient: true, trigger: trigger) }
        }
        guard prepared else { return false }
        guard waitForApplication(getpid()) else {
            DispatchQueue.main.async { if self.isTransient { self.leave() } }
            return false
        }
        return true
    }

    nonisolated func leaveFromHID() {
        let previous = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let pid = self.previousApp?.processIdentifier
                self.leave()
                return pid
            }
        }
        if let previous { _ = waitForApplication(previous) }
    }

    nonisolated private func waitForApplication(_ pid: pid_t) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        repeat {
            let ready = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let ready = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                        && (pid != getpid() || (self.isTransient && NSApp.isActive && self.panel?.isKeyWindow == true))
                    if ready && pid == getpid() { self.trace("activation-ready") }
                    return ready
                }
            }
            if ready { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func trace(_ event: String) {
        let entry: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
            "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "applicationPID": getpid(),
            "transient": closeOnIdle, "applicationActive": NSApp.isActive, "input": snapshot]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        print("DJF voice " + String(decoding: data, as: UTF8.self)); fflush(stdout)
    }

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

    func prepare(transient: Bool = false, trigger: UInt16 = UInt16(kVK_RightOption)) -> Bool {
        if panel != nil { restoreFocus(); return true }
        self.trigger = trigger
        let sources = TISCreateInputSourceList([kTISPropertyBundleID as String: "com.bytedance.inputmethod.doubaoime"] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first(where: { item in
            guard let value = TISGetInputSourceProperty(item, kTISPropertyInputSourceIsSelectCapable) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
        }) else { onStatus?("Mac 豆包输入法未启用"); return false }
        // Select the existing IME for this client so its transcription reaches
        // our text view. Restore the user's previous source when it closes.
        previousSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        previousApp = NSWorkspace.shared.frontmostApplication
        closeOnIdle = transient
        let left = NSScreen.screens.map { $0.frame.minX }.min() ?? 0
        let panel = SpeechInputPanel(contentRect: NSRect(x: left - 480, y: 0, width: 460, height: 170),
            styleMask: transient ? [.borderless] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "DJF 语音输入通道"
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.alphaValue = 0; panel.isOpaque = false; panel.hasShadow = false
        panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        panel.collectionBehavior = transient
            ? [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = VoiceTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        view.font = .systemFont(ofSize: 16); view.isRichText = false; view.delegate = self
        view.onCompositionChange = { [weak self] marked in self?.publishText(marked: marked) }
        panel.contentView?.addSubview(view)
        self.panel = panel; textView = view
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trace("resign-key") }
            DispatchQueue.main.async { self?.restoreFocus() }
        }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] _ in
            self?.restoreFocus()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        if transient { NSApp.activate(ignoringOtherApps: true) }
        guard TISSelectInputSource(source) == noErr else { close(); onStatus?("无法选择 Mac 豆包输入法"); return false }
        view.inputContext?.activate()
        trace("prepared")
        return true
    }

    // An RDP click takes Mac keyboard focus away from our IME client.
    // Keep the same IME client during recording without reselecting its source.
    // A transient client must not take focus back from another Mac app.
    func restoreFocus() {
        guard NSEvent.pressedMouseButtons == 0,
              let panel, let textView, !panel.isKeyWindow else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if closeOnIdle && front != previousApp?.processIdentifier && front != getpid() { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        trace("focus-restored")
    }

    private func begin(trigger: UInt16) {
        self.trigger = trigger; ending = false; discard = false; toggleReleased = false
        session = UUID().uuidString; changedAt = .distantPast
        lastSentText = ""; updates = 0; draftUpdates = 0
        onBegin?(session); onActive?(true)
        trace("begin")
    }

    func textDidChange(_ notification: Notification) {
        publishText(marked: textView?.hasMarkedText() ?? false)
    }

    private func publishText(marked: Bool) {
        guard !clearing, panel != nil else { return }
        if session.isEmpty { begin(trigger: trigger) }
        changedAt = Date()
        if !discard {
            let text = textView?.string ?? ""
            guard text != lastSentText else { return }
            lastSentText = text; updates += 1
            if marked { draftUpdates += 1 }
            trace("text-update")
            onUpdate?(session, text)
        }
    }

    private func finish() {
        guard !ending else { return }
        ending = true; endStarted = Date()
        onActive?(false)
        trace("finishing")
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

    func cancel(restoreFocus: Bool = true) {
        guard !session.isEmpty else { return }
        trace("cancel")
        discard = true; onCancel?(session)
        MacVoiceEvents.cancellationEvents(trigger: trigger).forEach(MacVoiceEvents.post)
        clearSession(restoreFocus: restoreFocus)
        onStatus?("语音输入已停止")
    }

    private func clearSession(restoreFocus: Bool = true) {
        timer?.invalidate(); timer = nil
        clearing = true; textView?.unmarkText(); textView?.string = ""; clearing = false
        lastSentText = ""
        session = ""; ending = false; onActive?(false)
        if closeOnIdle { close() } else if restoreFocus { self.restoreFocus() }
    }

    func leave(restoreSource: Bool = true) {
        if panel != nil { trace("leave") }
        if !restoreSource { previousSource = nil }
        cancel(restoreFocus: false); close(deferDeactivation: !restoreSource)
    }

    private func close(deferDeactivation: Bool = false) {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        timer?.invalidate(); timer = nil
        let view = textView
        view?.delegate = nil; view?.onCompositionChange = nil
        panel?.orderOut(nil); panel = nil; textView = nil
        if deferDeactivation {
            // NSTextInputContext doesn't retain its client. Keep the view alive
            // until the deferred deactivation has finished.
            DispatchQueue.main.async { [weak self, view] in
                guard self?.panel == nil else { return }
                view?.inputContext?.deactivate()
            }
        } else { view?.inputContext?.deactivate() }
        view?.string = ""
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { previousApp?.activate(options: []) }
        previousApp = nil
        if let previousSource,
           !CFEqual(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), previousSource) {
            TISSelectInputSource(previousSource)
        }
        previousSource = nil; closeOnIdle = false; onActive?(false)
        trace("closed")
    }
}
