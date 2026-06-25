import SwiftUI
import AppKit

struct ShortcutsSettingsView: View {
    @State private var combos: [ShortcutAction: KeyCombo] = {
        var d: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases {
            d[action] = ShortcutManager.shared.combo(for: action)
        }
        return d
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(ShortcutAction.allCases, columns: {
                TableColumn("Action") { action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.displayName)
                            .font(.system(size: 12))
                        Text(action.isGlobal ? "Global" : "In Popup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 150, ideal: 180)

                TableColumn("Shortcut") { action in
                    ShortcutRecorderCell(
                        combo: Binding(
                            get: { combos[action] ?? action.defaultCombo },
                            set: { newCombo in
                                combos[action] = newCombo
                                ShortcutManager.shared.setCombo(newCombo, for: action)
                            }
                        )
                    )
                }
                .width(min: 120, ideal: 140)

                TableColumn("") { action in
                    Button("Reset") {
                        ShortcutManager.shared.resetToDefault(action)
                        combos[action] = action.defaultCombo
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .width(50)
            })
        }
        .padding()
    }
}

struct ShortcutRecorderCell: View {
    @Binding var combo: KeyCombo
    @State private var isRecording = false

    var body: some View {
        ShortcutRecorderView(combo: $combo, isRecording: $isRecording)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
            )
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var combo: KeyCombo
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onComboChange = { newCombo in
            combo = newCombo
        }
        view.onRecordingChange = { recording in
            isRecording = recording
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.displayCombo = combo
    }
}

final class ShortcutRecorderNSView: NSView {
    var displayCombo: KeyCombo = KeyCombo(keyCode: 0, modifiers: []) {
        didSet { needsDisplay = true }
    }
    var onComboChange: ((KeyCombo) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let text = isRecording ? "Press shortcut…" : displayCombo.displayString
        let color: NSColor = isRecording ? .labelColor.withAlphaComponent(0.5) : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let x = (bounds.width - size.width) / 2
        let y = (bounds.height - size.height) / 2
        str.draw(at: NSPoint(x: x, y: y))
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        onRecordingChange?(true)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        // Delete/Escape cancels recording without changing
        if event.keyCode == 53 { // Escape
            stopRecording()
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = UInt16(event.keyCode)

        // Require at least one modifier for non-function keys
        let isFunctionKey = keyCode >= 96 && keyCode <= 121
        let hasModifier = !modifiers.intersection([.command, .option, .control, .shift]).isEmpty
        guard hasModifier || isFunctionKey else { return }

        let newCombo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        displayCombo = newCombo
        onComboChange?(newCombo)
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        onRecordingChange?(false)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }
}
