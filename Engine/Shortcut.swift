import Carbon
import CoreGraphics

struct RouterShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    static let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    static let toggle = RouterShortcut(keyCode: UInt16(kVK_Space), modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
    static let emergency = RouterShortcut(keyCode: UInt16(kVK_Escape), modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)

    struct Key: Identifiable {
        let code: UInt16
        let title: String
        let deskflow: String
        var id: UInt16 { code }
    }
    static let keys: [Key] = {
        var items: [Key] = [
            Key(code: UInt16(kVK_Space), title: "空格", deskflow: "space"),
            Key(code: UInt16(kVK_Escape), title: "Esc", deskflow: "Escape"),
            Key(code: UInt16(kVK_Tab), title: "Tab", deskflow: "Tab"),
            Key(code: UInt16(kVK_Return), title: "Return", deskflow: "Return")]
        let letters: [(Int, String)] = [(kVK_ANSI_A,"A"),(kVK_ANSI_B,"B"),(kVK_ANSI_C,"C"),(kVK_ANSI_D,"D"),
            (kVK_ANSI_E,"E"),(kVK_ANSI_F,"F"),(kVK_ANSI_G,"G"),(kVK_ANSI_H,"H"),(kVK_ANSI_I,"I"),
            (kVK_ANSI_J,"J"),(kVK_ANSI_K,"K"),(kVK_ANSI_L,"L"),(kVK_ANSI_M,"M"),(kVK_ANSI_N,"N"),
            (kVK_ANSI_O,"O"),(kVK_ANSI_P,"P"),(kVK_ANSI_Q,"Q"),(kVK_ANSI_R,"R"),(kVK_ANSI_S,"S"),
            (kVK_ANSI_T,"T"),(kVK_ANSI_U,"U"),(kVK_ANSI_V,"V"),(kVK_ANSI_W,"W"),(kVK_ANSI_X,"X"),
            (kVK_ANSI_Y,"Y"),(kVK_ANSI_Z,"Z"),(kVK_ANSI_0,"0"),(kVK_ANSI_1,"1"),(kVK_ANSI_2,"2"),
            (kVK_ANSI_3,"3"),(kVK_ANSI_4,"4"),(kVK_ANSI_5,"5"),(kVK_ANSI_6,"6"),(kVK_ANSI_7,"7"),
            (kVK_ANSI_8,"8"),(kVK_ANSI_9,"9")]
        items += letters.map { Key(code: UInt16($0.0), title: $0.1, deskflow: $0.1.lowercased()) }
        let functions = [kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17]
        items += functions.enumerated().map { Key(code: UInt16($0.element), title: "F\($0.offset+1)", deskflow: "F\($0.offset+1)") }
        return items
    }()

    var title: String {
        let flags = CGEventFlags(rawValue: modifiers)
        let symbols: [(CGEventFlags, String)] = [(.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        let prefix = symbols.filter { flags.contains($0.0) }.map(\.1).joined(separator: " ")
        return [prefix, Self.keys.first { $0.code == keyCode }?.title ?? "?"].filter { !$0.isEmpty }.joined(separator: " ")
    }
    var deskflow: String {
        let flags = CGEventFlags(rawValue: modifiers)
        let names: [(CGEventFlags, String)] = [(.maskControl, "Control"), (.maskAlternate, "Alt"), (.maskShift, "Shift"), (.maskCommand, "Super")]
        let parts = names.filter { flags.contains($0.0) }.map(\.1)
        return (parts + [Self.keys.first { $0.code == keyCode }!.deskflow]).joined(separator: "+")
    }
    var valid: Bool {
        Self.keys.contains { $0.code == keyCode } &&
            (modifiers != 0 || (Self.keys.first { $0.code == keyCode }?.deskflow.hasPrefix("F") ?? false))
    }
    var isFunctionKey: Bool { Self.keys.first { $0.code == keyCode }?.deskflow.hasPrefix("F") ?? false }
    func matches(_ code: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == code && flags.intersection(Self.modifierMask).rawValue == modifiers
    }
}
