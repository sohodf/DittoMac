import AppKit

@MainActor
final class AppIconFetcher {
    static let shared = AppIconFetcher()
    private var cache: [String: NSImage] = [:]

    func icon(for bundleID: String?) -> NSImage {
        guard let bundleID = bundleID else { return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) ?? NSImage() }
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared.icon(forFile: appPath(for: bundleID) ?? "")
        image.size = NSSize(width: 16, height: 16)
        cache[bundleID] = image
        return image
    }

    private func appPath(for bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }
}
