import AppKit
import Carbon

// Global var lets the C callback reach the manager without a raw pointer capture
nonisolated(unsafe) private var _shortcutManager: ShortcutManager? = nil

enum ShortcutAction: String, CaseIterable, Identifiable {
    var id: String { rawValue }

    case togglePopup
    case paste
    case pastePlainText
    case copyToClipboard
    case pin
    case delete
    case dismiss
    case focusSearch
    case openSettings
    case navigateUp
    case navigateDown

    var displayName: String {
        switch self {
        case .togglePopup:      return "Open / Close Popup"
        case .paste:            return "Paste Selected"
        case .pastePlainText:   return "Paste as Plain Text"
        case .copyToClipboard:  return "Copy to Clipboard"
        case .pin:              return "Toggle Pin"
        case .delete:           return "Delete Clip"
        case .dismiss:          return "Dismiss Popup"
        case .focusSearch:      return "Focus Search"
        case .openSettings:     return "Open Settings"
        case .navigateUp:       return "Navigate Up"
        case .navigateDown:     return "Navigate Down"
        }
    }

    var isGlobal: Bool { self == .togglePopup || self == .openSettings }

    var defaultCombo: KeyCombo {
        switch self {
        case .togglePopup:    return KeyCombo(keyCode: 9,   modifiers: [.command, .shift]) // ⌘⇧V
        case .paste:            return KeyCombo(keyCode: 36,  modifiers: [])                  // ↩
        case .pastePlainText:  return KeyCombo(keyCode: 36,  modifiers: [.shift])            // ⇧↩
        case .copyToClipboard: return KeyCombo(keyCode: 8,   modifiers: [.command])          // ⌘C
        case .pin:             return KeyCombo(keyCode: 2,   modifiers: [.command])          // ⌘D
        case .delete:         return KeyCombo(keyCode: 51,  modifiers: [])                  // ⌫
        case .dismiss:        return KeyCombo(keyCode: 53,  modifiers: [])                  // ⎋
        case .focusSearch:    return KeyCombo(keyCode: 3,   modifiers: [.command])          // ⌘F
        case .openSettings:   return KeyCombo(keyCode: 43,  modifiers: [.command])          // ⌘,
        case .navigateUp:     return KeyCombo(keyCode: 126, modifiers: [])                  // ↑
        case .navigateDown:   return KeyCombo(keyCode: 125, modifiers: [])                  // ↓
        }
    }
}

struct KeyCombo: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifierFlagsRaw: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifiers.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
    }

    var displayString: String {
        var s = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += Self.keyCodeNames[keyCode] ?? "(\(keyCode))"
        return s
    }

    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    static let keyCodeNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 122: "F1", 120: "F2",
        118: "F4", 115: "Home", 116: "PgUp", 117: "⌦", 119: "End", 121: "PgDn",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

@MainActor
final class ShortcutManager {
    static let shared = ShortcutManager()

    /// Set once by AppDelegate. Never overwritten by popup controller.
    var onGlobalAction: ((ShortcutAction) -> Void)?
    /// Set by PopupWindowController while popup is open, cleared on dismiss.
    var onLocalAction: ((ShortcutAction) -> Void)?

    private var globalHotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?

    // MARK: Shortcut persistence

    func combo(for action: ShortcutAction) -> KeyCombo {
        let key = "shortcut_\(action.rawValue)"
        if let data = UserDefaults.standard.data(forKey: key),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            return combo
        }
        return action.defaultCombo
    }

    func setCombo(_ combo: KeyCombo, for action: ShortcutAction) {
        let key = "shortcut_\(action.rawValue)"
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if action.isGlobal { reregisterGlobal(action) }
    }

    func resetToDefault(_ action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: "shortcut_\(action.rawValue)")
        if action.isGlobal { reregisterGlobal(action) }
    }

    // MARK: Global hotkeys (Carbon)

    func registerGlobalHotKeys() {
        _shortcutManager = self

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1, &spec,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            print("[ShortcutManager] InstallEventHandler failed: \(status)")
        }

        for action in ShortcutAction.allCases where action.isGlobal {
            registerGlobal(action)
        }
    }

    private func registerGlobal(_ action: ShortcutAction) {
        let c = combo(for: action)
        let index = UInt32(ShortcutAction.allCases.firstIndex(of: action) ?? 0) + 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x44494D43), id: index) // 'DIMC'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(c.keyCode),
            c.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref = ref {
            globalHotKeyRefs[action] = ref
        } else {
            print("[ShortcutManager] RegisterEventHotKey failed for \(action.displayName): \(status)")
        }
    }

    private func reregisterGlobal(_ action: ShortcutAction) {
        if let ref = globalHotKeyRefs[action] {
            UnregisterEventHotKey(ref)
            globalHotKeyRefs.removeValue(forKey: action)
        }
        registerGlobal(action)
    }

    func handleGlobalHotKey(id: UInt32) {
        let idx = Int(id) - 1
        guard idx >= 0, idx < ShortcutAction.allCases.count else { return }
        let action = ShortcutAction.allCases[idx]
        guard action.isGlobal else { return }
        onGlobalAction?(action)
    }

    // MARK: Local key monitoring (popup open)

    func startLocalMonitoring() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleLocalKeyEvent(event) { return nil }
            return event
        }
    }

    func stopLocalMonitoring() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        onLocalAction = nil
    }

    // Only these four matter for shortcut matching; numericPad/function/capsLock are noise.
    private static let realMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private func handleLocalKeyEvent(_ event: NSEvent) -> Bool {
        let keyCode  = UInt16(event.keyCode)
        let mods     = event.modifierFlags.intersection(Self.realMods)

        for action in ShortcutAction.allCases where !action.isGlobal {
            let c        = combo(for: action)
            let expected = NSEvent.ModifierFlags(rawValue: c.modifierFlagsRaw).intersection(Self.realMods)
            guard c.keyCode == keyCode && expected == mods else { continue }

            // Don't steal ⌫ from the search field while the user is editing the query.
            if action == .delete,
               let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView { return false }

            onLocalAction?(action)
            return true
        }
        return false
    }
}

// C-compatible callback — accesses the manager via the file-scope global
private func carbonHotKeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    let hkID = hotKeyID.id
    DispatchQueue.main.async {
        _shortcutManager?.handleGlobalHotKey(id: hkID)
    }
    return noErr
}
