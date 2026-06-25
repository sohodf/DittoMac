import AppKit
import Combine
import os.log

private let clipLogger = Logger(subsystem: "com.dittomac.app", category: "ClipboardMonitor")

@MainActor
final class ClipboardMonitor {
    var onNewClip: ((ClipboardEntry) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let pollInterval: TimeInterval = 0.5
    private var pollCount = 0

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        clipLogger.info("Starting. Initial changeCount: \(self.lastChangeCount)")
        timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        clipLogger.info("Timer added to main run loop")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        pollCount += 1
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != self.lastChangeCount else { return }
        clipLogger.info("Clipboard changed \(self.lastChangeCount) -> \(current)")
        lastChangeCount = current

        guard let entry = extract(from: pb) else {
            clipLogger.info("No extractable content")
            return
        }

        let excluded = UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []
        if let src = entry.sourceApp, excluded.contains(src) {
            clipLogger.info("Ignored: excluded app \(src)")
            return
        }

        clipLogger.info("New clip: type=\(entry.contentType.rawValue) crc=\(entry.crc32)")
        onNewClip?(entry)
    }

    private func extract(from pasteboard: NSPasteboard) -> ClipboardEntry? {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName

        if sourceApp == Bundle.main.bundleIdentifier { return nil }

        let now = Date()
        let types = pasteboard.types ?? []

        // Image
        if types.contains(.png) || types.contains(.tiff) {
            if let image = NSImage(pasteboard: pasteboard),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                let content = "[Image \(Int(image.size.width))×\(Int(image.size.height))]"
                return ClipboardEntry(
                    id: nil, contentType: .image, content: content,
                    contentRTF: nil, contentImage: pngData, contentFiles: nil,
                    sourceApp: sourceApp, sourceAppName: sourceAppName,
                    createdAt: now, lastPastedAt: nil, pasteCount: 0,
                    isPinned: false, pinOrder: nil, title: nil,
                    crc32: CRC32.checksum(pngData)
                )
            }
        }

        // File paths
        if let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String], !paths.isEmpty {
            let joined = paths.joined(separator: "\n")
            return ClipboardEntry(
                id: nil, contentType: .file, content: joined,
                contentRTF: nil, contentImage: nil, contentFiles: joined,
                sourceApp: sourceApp, sourceAppName: sourceAppName,
                createdAt: now, lastPastedAt: nil, pasteCount: 0,
                isPinned: false, pinOrder: nil, title: nil,
                crc32: CRC32.checksum(Data(joined.utf8))
            )
        }

        // RTF
        if types.contains(.rtf), let rtfData = pasteboard.data(forType: .rtf) {
            let plainText = (try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
            guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ClipboardEntry(
                id: nil, contentType: .rtf, content: plainText,
                contentRTF: rtfData, contentImage: nil, contentFiles: nil,
                sourceApp: sourceApp, sourceAppName: sourceAppName,
                createdAt: now, lastPastedAt: nil, pasteCount: 0,
                isPinned: false, pinOrder: nil, title: nil,
                crc32: CRC32.checksum(rtfData)
            )
        }

        // Plain text
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClipboardEntry(
                id: nil, contentType: .text, content: text,
                contentRTF: nil, contentImage: nil, contentFiles: nil,
                sourceApp: sourceApp, sourceAppName: sourceAppName,
                createdAt: now, lastPastedAt: nil, pasteCount: 0,
                isPinned: false, pinOrder: nil, title: nil,
                crc32: CRC32.checksum(Data(text.utf8))
            )
        }

        return nil
    }
}
