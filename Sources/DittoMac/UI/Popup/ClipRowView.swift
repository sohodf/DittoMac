import SwiftUI

struct ClipRowView: View {
    let entry: ClipboardEntry
    @EnvironmentObject var vm: ClipsViewModel

    private var isSelected: Bool { vm.selectedID == entry.id }

    var body: some View {
        HStack(spacing: 8) {
            // Source app icon
            appIcon

            // Content preview
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.preview)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 6) {
                    typeBadge
                    if let name = entry.sourceAppName {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    }
                    Spacer()
                    Text(RelativeDate.string(from: entry.createdAt))
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }
            }

            // Pin indicator
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.selectedID = entry.id
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            vm.selectedID = entry.id
            // Double-tap pastes
            NotificationCenter.default.post(name: .pasteSelectedClip, object: nil)
        })
        .contextMenu {
            contextMenuItems
        }
    }

    private var appIcon: some View {
        let icon = AppIconFetcher.shared.icon(for: entry.sourceApp)
        return Image(nsImage: icon)
            .resizable()
            .frame(width: 16, height: 16)
    }

    private var typeBadge: some View {
        let label: String
        switch entry.contentType {
        case .text:  label = "TXT"
        case .rtf:   label = "RTF"
        case .image: label = "IMG"
        case .file:  label = "FILE"
        }
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(isSelected ? .white.opacity(0.2) : Color.accentColor.opacity(0.15))
            )
            .foregroundStyle(isSelected ? .white.opacity(0.9) : .accentColor)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(entry.isPinned ? "Unpin" : "Pin") {
            Task { await vm.togglePin(entry) }
        }
        Divider()
        Button("Copy to Clipboard") {
            PasteHelper.write(entry: entry, plainTextOnly: false)
        }
        Button("Copy as Plain Text") {
            PasteHelper.write(entry: entry, plainTextOnly: true)
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await vm.delete(entry) }
        }
    }
}

extension Notification.Name {
    static let pasteSelectedClip = Notification.Name("DittoMacPasteSelectedClip")
}
