import Carbon
import CoreGraphics

/// One modifier projection for Deskflow and the native RDP shortcut channel.
enum WindowsKeyboard {
    private static let modifiers: [(CGEventFlags, UInt64, UInt64, Int, Int, String?)] = [
        (.maskCommand, 0x8, 0x10, 1, 2, "modifierSuper=ctrl"),
        (.maskControl, 0x1, 0x2000, 4, 8, "modifierCtrl=super"),
        (.maskShift, 0x2, 0x4, 16, 32, nil),
        (.maskAlternate, 0x20, 0x40, 64, 128, nil)]
    static var deskflowModifiers: String { modifiers.compactMap { $0.5 }.joined(separator: "\n") }
    static func modifierMask(_ flags: CGEventFlags) -> Int {
        var value = 0
        for (flag, left, right, lbit, rbit, _) in modifiers where flags.contains(flag) {
            if flags.rawValue & left != 0 { value |= lbit }
            if flags.rawValue & right != 0 { value |= rbit }
            if flags.rawValue & (left | right) == 0 { value |= lbit }
        }
        return value
    }
    static func pointerFlags(_ flags: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue & ~(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | 0x2019))
    }
    // Windows VK, with bit 8 marking extended keys. Text without these modifiers
    // stays in Windows App so its Unicode/IME path remains native.
    static let keys: [UInt16: UInt16] = {
        let values: [(Int, UInt16)] = [
            (kVK_ANSI_A,0x41),(kVK_ANSI_S,0x53),(kVK_ANSI_D,0x44),(kVK_ANSI_F,0x46),(kVK_ANSI_H,0x48),(kVK_ANSI_G,0x47),
            (kVK_ANSI_Z,0x5A),(kVK_ANSI_X,0x58),(kVK_ANSI_C,0x43),(kVK_ANSI_V,0x56),(kVK_ANSI_B,0x42),
            (kVK_ANSI_Q,0x51),(kVK_ANSI_W,0x57),(kVK_ANSI_E,0x45),(kVK_ANSI_R,0x52),(kVK_ANSI_Y,0x59),(kVK_ANSI_T,0x54),
            (kVK_ANSI_1,0x31),(kVK_ANSI_2,0x32),(kVK_ANSI_3,0x33),(kVK_ANSI_4,0x34),(kVK_ANSI_6,0x36),(kVK_ANSI_5,0x35),
            (kVK_ANSI_9,0x39),(kVK_ANSI_7,0x37),(kVK_ANSI_8,0x38),(kVK_ANSI_0,0x30),
            (kVK_ANSI_O,0x4F),(kVK_ANSI_U,0x55),(kVK_ANSI_I,0x49),(kVK_ANSI_P,0x50),(kVK_ANSI_L,0x4C),(kVK_ANSI_J,0x4A),
            (kVK_ANSI_K,0x4B),(kVK_ANSI_N,0x4E),(kVK_ANSI_M,0x4D),
            (kVK_ANSI_Equal,0xBB),(kVK_ANSI_Minus,0xBD),(kVK_ANSI_RightBracket,0xDD),(kVK_ANSI_LeftBracket,0xDB),
            (kVK_ANSI_Quote,0xDE),(kVK_ANSI_Semicolon,0xBA),(kVK_ANSI_Backslash,0xDC),(kVK_ANSI_Comma,0xBC),
            (kVK_ANSI_Slash,0xBF),(kVK_ANSI_Period,0xBE),(kVK_ANSI_Grave,0xC0),(kVK_ISO_Section,0xE2),
            (kVK_Return,0x0D),(kVK_Tab,0x09),(kVK_Space,0x20),(kVK_Delete,0x08),(kVK_Escape,0x1B),
            (kVK_Home,0x124),(kVK_End,0x123),(kVK_PageUp,0x121),(kVK_PageDown,0x122),(kVK_ForwardDelete,0x12E),(kVK_Help,0x12D),
            (kVK_LeftArrow,0x125),(kVK_RightArrow,0x127),(kVK_UpArrow,0x126),(kVK_DownArrow,0x128),
            (kVK_ANSI_KeypadDecimal,0x6E),(kVK_ANSI_KeypadMultiply,0x6A),(kVK_ANSI_KeypadPlus,0x6B),
            (kVK_ANSI_KeypadClear,0x190),(kVK_ANSI_KeypadDivide,0x16F),(kVK_ANSI_KeypadEnter,0x10D),(kVK_ANSI_KeypadMinus,0x6D),(kVK_ANSI_KeypadEquals,0xBB),
            (kVK_ANSI_Keypad0,0x60),(kVK_ANSI_Keypad1,0x61),(kVK_ANSI_Keypad2,0x62),(kVK_ANSI_Keypad3,0x63),(kVK_ANSI_Keypad4,0x64),
            (kVK_ANSI_Keypad5,0x65),(kVK_ANSI_Keypad6,0x66),(kVK_ANSI_Keypad7,0x67),(kVK_ANSI_Keypad8,0x68),(kVK_ANSI_Keypad9,0x69)]
        var result = Dictionary(uniqueKeysWithValues: values.map { (UInt16($0.0), $0.1) })
        for (i, key) in [kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17,kVK_F18,kVK_F19,kVK_F20].enumerated() { result[UInt16(key)] = UInt16(0x70 + i) }
        return result
    }()
}

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
