import AppKit
import SwiftUI

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupWindowController: NSWindowController {
    private var previousApp: NSRunningApplication?
    private var clickMonitor: Any?

    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        let panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let vm = ClipsViewModel.shared
        let hostingView = NSHostingView(rootView:
            MainView()
                .environmentObject(vm)
        )
        panel.contentView = hostingView

        super.init(window: panel)
    }

    required init?(coder: NSCoder) { nil }

    func show(relativeTo button: NSButton?) {
        previousApp = NSWorkspace.shared.frontmostApplication

        guard let panel = window else { return }

        // Position panel
        let frame = panel.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        if let button = button, let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: buttonRect.minX, y: buttonRect.minY - frame.height - 4)
        } else {
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height / 2)
        }

        // Keep on screen
        origin.x = max(screenFrame.minX, min(origin.x, screenFrame.maxX - frame.width))
        origin.y = max(screenFrame.minY, min(origin.y, screenFrame.maxY - frame.height))

        panel.setFrameOrigin(origin)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        ShortcutManager.shared.startLocalMonitoring()
        ShortcutManager.shared.onLocalAction = { [weak self] action in
            self?.handleAction(action)
        }

        // Monitor outside clicks
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let panel = self.window else { return }
            let screenLoc = NSEvent.mouseLocation
            if !panel.frame.contains(screenLoc) {
                DispatchQueue.main.async { self.dismiss() }
            }
        }

        Task { @MainActor in
            await ClipsViewModel.shared.refresh()
            ClipsViewModel.shared.selectFirst()
        }
    }

    func dismiss() {
        ShortcutManager.shared.stopLocalMonitoring()
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        window?.orderOut(nil)
        ClipsViewModel.shared.searchText = ""
    }

    func copySelected() {
        guard let entry = ClipsViewModel.shared.selectedEntry else { return }
        PasteHelper.write(entry: entry, plainTextOnly: false)
        let app = previousApp
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            app?.activate(options: .activateIgnoringOtherApps)
        }
    }

    func paste(plainTextOnly: Bool = false) {
        guard let entry = ClipsViewModel.shared.selectedEntry else { return }
        PasteHelper.write(entry: entry, plainTextOnly: plainTextOnly)
        if let id = entry.id {
            Task { try? await DatabaseManager.shared.recordPaste(id: id) }
        }
        let app = previousApp
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            app?.activate(options: .activateIgnoringOtherApps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                PasteHelper.postCmdV()
            }
        }
    }

    private func handleAction(_ action: ShortcutAction) {
        switch action {
        case .paste:             paste()
        case .pastePlainText:    paste(plainTextOnly: true)
        case .copyToClipboard:   copySelected()
        case .dismiss:        dismiss()
        case .navigateDown:   ClipsViewModel.shared.selectNext()
        case .navigateUp:     ClipsViewModel.shared.selectPrevious()
        case .pin:
            if let entry = ClipsViewModel.shared.selectedEntry {
                Task { await ClipsViewModel.shared.togglePin(entry) }
            }
        case .delete:
            if let entry = ClipsViewModel.shared.selectedEntry {
                Task { await ClipsViewModel.shared.delete(entry) }
            }
        case .focusSearch:
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
        case .openSettings:
            dismiss()
            SettingsWindowController.shared.show()
        case .togglePopup:
            break // handled globally in AppDelegate
        }
    }
}

extension Notification.Name {
    static let focusSearchField = Notification.Name("DittoMacFocusSearchField")
}
