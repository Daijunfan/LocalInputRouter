import AppKit

@main
@MainActor
enum VoiceTextChecks {
    static func main() {
        _ = NSApplication.shared
        let view = VoiceTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        view.isRichText = false
        var updates: [String] = []
        var drafts = 0
        view.onCompositionChange = { marked in
            updates.append(view.string)
            if marked { drafts += 1 }
        }
        for text in ["今天", "今天下五", "今天下午"] {
            view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            precondition(view.hasMarkedText(), "Draft must still be uncommitted")
        }
        precondition(updates == ["今天", "今天下五", "今天下午"] && drafts == 3,
                     "Partial transcripts must arrive before final commit, including corrections")
        view.insertText("今天下午两点开会", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        precondition(view.string == "今天下午两点开会" && !view.hasMarkedText(), "Final commit must replace the draft")
        view.unmarkText(); view.string = ""
        precondition(view.string.isEmpty && !view.hasMarkedText(), "Next recording must start with an empty field")
        print("PASS: native IME draft streaming, live corrections, final commit, and field reset")
    }
}
