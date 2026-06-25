import SwiftUI

struct StorageSettingsView: View {
    @State private var isCompacting = false
    @State private var compactDone = false

    var body: some View {
        Form {
            Section("Database") {
                LabeledContent("Location") {
                    Text(DatabaseManager.shared.databaseURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                LabeledContent("Size") {
                    Text(DatabaseManager.shared.databaseSize)
                        .foregroundStyle(.secondary)
                }

                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([DatabaseManager.shared.databaseURL])
                }

                Button(isCompacting ? "Compacting…" : compactDone ? "Done!" : "Compact Database") {
                    guard !isCompacting else { return }
                    isCompacting = true
                    Task {
                        try? await DatabaseManager.shared.vacuum()
                        isCompacting = false
                        compactDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            compactDone = false
                        }
                    }
                }
                .disabled(isCompacting)
            }

            Section("Danger Zone") {
                Button("Clear All History…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Clear All Clipboard History?"
                    alert.informativeText = "Pinned clips will be preserved. This cannot be undone."
                    alert.addButton(withTitle: "Clear History")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .warning
                    if alert.runModal() == .alertFirstButtonReturn {
                        Task {
                            try? await DatabaseManager.shared.clearHistory()
                            await ClipsViewModel.shared.refresh()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
