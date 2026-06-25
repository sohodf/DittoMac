import SwiftUI
import AppKit

struct SearchBarView: View {
    @Binding var text: String
    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            SearchTextField(text: $text, isFocused: $isFocused)
                .frame(height: 20)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5)
                )
        )
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isFocused = true
        }
    }
}

// NSTextField wrapper for reliable focus management
struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusAwareTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.placeholderString = "Search clips…"
        field.font = .systemFont(ofSize: 13)
        field.focusDelegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if isFocused && nsView.window?.firstResponder != nsView.currentEditor() {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate, FocusAwareTextFieldDelegate {
        var parent: SearchTextField

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        func didBecomeFirstResponder() { parent.isFocused = true }
        func didResignFirstResponder() { parent.isFocused = false }
    }
}

protocol FocusAwareTextFieldDelegate: AnyObject {
    func didBecomeFirstResponder()
    func didResignFirstResponder()
}

class FocusAwareTextField: NSTextField {
    weak var focusDelegate: FocusAwareTextFieldDelegate?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDelegate?.didBecomeFirstResponder() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDelegate?.didResignFirstResponder() }
        return result
    }
}
