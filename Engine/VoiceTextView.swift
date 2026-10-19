import AppKit

/// IME draft changes do not always emit NSTextView.textDidChange.
final class VoiceTextView: NSTextView {
    var onCompositionChange: ((Bool) -> Void)?

    override func setMarkedText(_ text: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?(true)
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
        onCompositionChange?(false)
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?(false)
    }
}

/// Routed speech takes keyboard focus; transient speech can activate its owner.
final class SpeechInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !styleMask.contains(.nonactivatingPanel) }
}
