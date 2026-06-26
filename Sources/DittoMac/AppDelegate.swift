import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private(set) var popupController: PopupWindowController?
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup database
        do {
            try DatabaseManager.shared.setup()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Database Error"
            alert.informativeText = "Failed to open database: \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.runModal()
        }

        // Setup popup
        let popup = PopupWindowController()
        self.popupController = popup

        // Setup clipboard monitor
        let monitor = ClipboardMonitor()
        monitor.onNewClip = { entry in
            Task {
                do {
                    guard try await !DatabaseManager.shared.isDuplicate(crc32: entry.crc32) else { return }
                    let settings = SettingsViewModel.shared
                    if entry.contentType == .image && !settings.captureImages { return }
                    if entry.contentType == .file  && !settings.captureFiles  { return }
                    try await DatabaseManager.shared.insert(entry)
                    await ClipsViewModel.shared.refresh()
                } catch {
                    print("Monitor insert error: \(error)")
                }
            }
        }
        monitor.start()
        self.clipboardMonitor = monitor

        // Setup status item
        setupStatusItem()

        // Setup global hotkeys
        ShortcutManager.shared.registerGlobalHotKeys()
        ShortcutManager.shared.onGlobalAction = { [weak self] action in
            self?.handleGlobalAction(action)
        }

        // Wire double-tap paste from ClipRowView
        NotificationCenter.default.addObserver(
            forName: .pasteSelectedClip,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.popupController?.paste() }
        }

        // Request Accessibility — required for CGEvent injection on macOS 14+.
        // The system shows its own dialog if not yet granted; does nothing if already granted.
        requestAccessibilityIfNeeded()
    }

    private func requestAccessibilityIfNeeded() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let storedVersion = UserDefaults.standard.string(forKey: "lastLaunchedVersion")
        let isUpgrade = storedVersion != nil && storedVersion != currentVersion
        UserDefaults.standard.set(currentVersion, forKey: "lastLaunchedVersion")

        guard !AXIsProcessTrusted() else { return }

        if isUpgrade {
            // Replacing the binary invalidates the TCC entry even for unsigned apps on macOS 13+.
            // Resetting the entry allows the system to issue a fresh grant.
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.dittomac.app"]
            try? reset.run()
            reset.waitUntilExit()

            if reset.terminationStatus != 0 {
                showManualAccessibilityResetAlert()
                return
            }
        }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private func showManualAccessibilityResetAlert() {
        let alert = NSAlert()
        alert.messageText = "Re-grant Accessibility Access"
        alert.informativeText = "DittoMac was updated. To restore paste functionality:\n\n1. Open System Settings → Privacy & Security → Accessibility\n2. Find DittoMac and toggle it off, then back on."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Status Item

    private var statusMenu: NSMenu?

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        if let img = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "DittoMac") {
            img.isTemplate = true
            button.image = img
        }
        // Left-click → popup, right-click → menu
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(statusButtonClicked(_:))

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open DittoMac", action: #selector(togglePopup), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit DittoMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusMenu = menu
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // Show the context menu on right-click
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePopup()
        }
    }

    // MARK: Actions

    @objc func togglePopup() {
        guard let popup = popupController else { return }
        if popup.isVisible {
            popup.dismiss()
        } else {
            popup.show(relativeTo: statusItem?.button)
        }
    }

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Clipboard History?"
        alert.informativeText = "All clips except pinned ones will be permanently deleted."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            try? await DatabaseManager.shared.clearHistory()
            await ClipsViewModel.shared.refresh()
        }
    }

    private func handleGlobalAction(_ action: ShortcutAction) {
        switch action {
        case .togglePopup:  togglePopup()
        case .openSettings: openSettings()
        default: break
        }
    }

}
