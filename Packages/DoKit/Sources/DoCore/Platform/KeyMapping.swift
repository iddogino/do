import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A resolved key chord: virtual key codes for modifiers and the final key.
public struct KeyChord: Equatable, Sendable {
    public var modifiers: [CGKeyCode]
    public var flags: CGEventFlags
    public var key: CGKeyCode?

    public init(modifiers: [CGKeyCode] = [], flags: CGEventFlags = [], key: CGKeyCode?) {
        self.modifiers = modifiers
        self.flags = flags
        self.key = key
    }

    public static func == (a: KeyChord, b: KeyChord) -> Bool {
        a.modifiers == b.modifiers && a.flags.rawValue == b.flags.rawValue && a.key == b.key
    }
}

public enum KeyMappingError: Error, LocalizedError, Equatable {
    case unknownKey(String)
    public var errorDescription: String? {
        switch self {
        case .unknownKey(let k): "Unknown key \"\(k)\"."
        }
    }
}

/// Maps the model's key names (pyautogui / xdotool flavoured, trained on Linux) onto macOS
/// virtual key codes.
public enum KeyMapping {

    public enum Modifier: Sendable {
        case command, control, option, shift, function

        public var keyCode: CGKeyCode {
            switch self {
            case .command: CGKeyCode(kVK_Command)
            case .control: CGKeyCode(kVK_Control)
            case .option: CGKeyCode(kVK_Option)
            case .shift: CGKeyCode(kVK_Shift)
            case .function: CGKeyCode(kVK_Function)
            }
        }

        public var flag: CGEventFlags {
            switch self {
            case .command: .maskCommand
            case .control: .maskControl
            case .option: .maskAlternate
            case .shift: .maskShift
            case .function: .maskSecondaryFn
            }
        }
    }

    public static func modifier(named raw: String) -> Modifier? {
        switch normalize(raw) {
        case "cmd", "command", "meta", "super", "win", "windows", "⌘": .command
        case "ctrl", "control", "ctl", "⌃": .control
        case "alt", "option", "opt", "altgr", "⌥": .option
        case "shift", "⇧": .shift
        case "fn", "function": .function
        default: nil
        }
    }

    static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        // Keep single printable characters verbatim (case matters for e.g. "A" vs "a" is moot,
        // but symbols like "+" must survive).
        if t.count == 1 { return t.lowercased() }
        return t.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
    }

    /// Named, layout-independent keys.
    static let namedKeys: [String: Int] = [
        "enter": kVK_Return, "return": kVK_Return, "kpenter": kVK_ANSI_KeypadEnter,
        "tab": kVK_Tab, "space": kVK_Space, "spacebar": kVK_Space,
        "backspace": kVK_Delete, "bksp": kVK_Delete,
        "delete": kVK_ForwardDelete, "del": kVK_ForwardDelete, "forwarddelete": kVK_ForwardDelete,
        "esc": kVK_Escape, "escape": kVK_Escape,
        "up": kVK_UpArrow, "arrowup": kVK_UpArrow, "down": kVK_DownArrow, "arrowdown": kVK_DownArrow,
        "left": kVK_LeftArrow, "arrowleft": kVK_LeftArrow, "right": kVK_RightArrow, "arrowright": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pgup": kVK_PageUp,
        "pagedown": kVK_PageDown, "pgdn": kVK_PageDown,
        "capslock": kVK_CapsLock, "insert": kVK_Help, "help": kVK_Help,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17,
        "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "volumeup": kVK_VolumeUp, "volumedown": kVK_VolumeDown, "volumemute": kVK_Mute,
        "plus": kVK_ANSI_Equal, "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
        "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash,
        "backslash": kVK_ANSI_Backslash, "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
        "apostrophe": kVK_ANSI_Quote, "grave": kVK_ANSI_Grave, "backtick": kVK_ANSI_Grave,
        "bracketleft": kVK_ANSI_LeftBracket, "bracketright": kVK_ANSI_RightBracket,
    ]

    /// US-ANSI fallback for printable characters when the current layout can't be queried.
    static let ansiCharacters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
    ]

    /// Shifted US-ANSI symbols: the base key plus an implied Shift.
    static let shiftedANSI: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`",
    ]

    /// Resolves a list of key names into a chord. Elements may themselves be "ctrl+c" style.
    /// - Parameter layout: character → key code lookup for the active keyboard layout.
    public static func chord(for names: [String], layout: KeyboardLayout? = .current) throws -> KeyChord {
        var parts: [String] = []
        for name in names {
            let t = name.trimmingCharacters(in: .whitespaces)
            if t.count > 1, t.contains("+") {
                parts += t.split(separator: "+").map(String.init).filter { !$0.isEmpty }
            } else if !t.isEmpty {
                parts.append(t)
            }
        }
        var modifiers: [Modifier] = []
        var key: CGKeyCode?
        for part in parts {
            if let m = modifier(named: part) {
                if !modifiers.contains(m) { modifiers.append(m) }
                continue
            }
            let (code, needsShift) = try keyCode(for: part, layout: layout)
            if needsShift, !modifiers.contains(.shift) { modifiers.append(.shift) }
            key = code
        }
        var flags: CGEventFlags = []
        for m in modifiers { flags.insert(m.flag) }
        return KeyChord(modifiers: modifiers.map(\.keyCode), flags: flags, key: key)
    }

    static func keyCode(for raw: String, layout: KeyboardLayout?) throws -> (CGKeyCode, needsShift: Bool) {
        let name = normalize(raw)
        if let named = namedKeys[name] { return (CGKeyCode(named), false) }
        guard name.count == 1, let ch = raw.trimmingCharacters(in: .whitespaces).first else {
            throw KeyMappingError.unknownKey(raw)
        }
        let lower = Character(ch.lowercased())
        if let layout, let hit = layout.keyCode(for: lower) {
            return (hit.code, hit.shift || (ch.isUppercase && ch.isLetter))
        }
        if let code = ansiCharacters[lower] { return (CGKeyCode(code), ch.isUppercase && ch.isLetter) }
        if let base = shiftedANSI[ch], let code = ansiCharacters[base] { return (CGKeyCode(code), true) }
        throw KeyMappingError.unknownKey(raw)
    }

    /// Linux-trained policies reach for Ctrl where a Mac uses Command. For the standard
    /// editing/navigation shortcuts outside terminals, swap Control for Command.
    public static func translatingLinuxShortcuts(_ names: [String]) -> [String] {
        let lowered = names.map { normalize($0) }
        let hasControl = lowered.contains { modifier(named: $0) == .control }
        let hasCommand = lowered.contains { modifier(named: $0) == .command }
        guard hasControl, !hasCommand else { return names }
        let others = lowered.filter { modifier(named: $0) == nil }
        let translatable: Set<String> = [
            "a", "c", "v", "x", "z", "y", "s", "f", "t", "w", "n", "o", "p", "l", "r", "q", "b", "i", "u",
            "k", "g", "h", "d", "e", "j", "m", "=", "-", "0", "plus", "minus", "equal", "home", "end", "tab", "enter", "return",
        ]
        guard others.count == 1, translatable.contains(others[0]) else { return names }
        return names.map { modifier(named: $0) == .control ? "cmd" : $0 }
    }
}

/// Reverse lookup from characters to key codes for the active keyboard layout.
public struct KeyboardLayout: Sendable {
    private let table: [Character: (code: CGKeyCode, shift: Bool)]

    init(table: [Character: (code: CGKeyCode, shift: Bool)]) {
        self.table = table
    }

    public func keyCode(for ch: Character) -> (code: CGKeyCode, shift: Bool)? {
        table[ch]
    }

    /// Snapshot of the current ASCII-capable layout, or nil if it can't be read.
    public static var current: KeyboardLayout? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var table: [Character: (code: CGKeyCode, shift: Bool)] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {
                for code in 0 ..< 128 {
                    var dead: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let modifierState: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                    let status = UCKeyTranslate(
                        layout, UInt16(code), UInt16(kUCKeyActionDown), modifierState,
                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead,
                        chars.count, &length, &chars)
                    guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let ch = Character(scalar)
                    guard !ch.isWhitespace, scalar.value >= 0x20 else { continue }
                    // Prefer the unshifted mapping when a character is reachable both ways.
                    if table[ch] == nil { table[ch] = (CGKeyCode(code), shift) }
                }
            }
        }
        return table.isEmpty ? nil : KeyboardLayout(table: table)
    }
}
