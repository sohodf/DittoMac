import AppKit

enum PasteHelper {
    static func write(entry: ClipboardEntry, plainTextOnly: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if plainTextOnly {
            pasteboard.setString(entry.content, forType: .string)
            return
        }

        for (type, data) in entry.writeToNSPasteboard {
            pasteboard.setData(data, forType: type)
        }
        // Always include plain text fallback
        if !entry.content.isEmpty {
            pasteboard.setString(entry.content, forType: .string)
        }
    }

    static func postCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        // .cghidEventTap is required on macOS 14+ for reliable injection; needs Accessibility permission.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
