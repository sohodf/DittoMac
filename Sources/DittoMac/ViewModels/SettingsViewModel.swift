import Foundation
import ServiceManagement
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    static let shared = SettingsViewModel()

    @Published var historyLimit: Int {
        didSet { UserDefaults.standard.set(historyLimit, forKey: "historyLimit") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }
    @Published var popupPosition: PopupPosition {
        didSet { UserDefaults.standard.set(popupPosition.rawValue, forKey: "popupPosition") }
    }
    @Published var captureImages: Bool {
        didSet { UserDefaults.standard.set(captureImages, forKey: "captureImages") }
    }
    @Published var captureFiles: Bool {
        didSet { UserDefaults.standard.set(captureFiles, forKey: "captureFiles") }
    }
    @Published var excludedApps: [String] {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "excludedApps") }
    }

    init() {
        let ud = UserDefaults.standard
        let limit = ud.integer(forKey: "historyLimit")
        historyLimit = limit > 0 ? limit : 500
        launchAtLogin = (try? SMAppService.mainApp.status == .enabled) ?? false
        popupPosition = PopupPosition(rawValue: ud.string(forKey: "popupPosition") ?? "") ?? .atCursor
        captureImages = ud.object(forKey: "captureImages") as? Bool ?? true
        captureFiles  = ud.object(forKey: "captureFiles")  as? Bool ?? true
        excludedApps  = ud.stringArray(forKey: "excludedApps") ?? []
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("LaunchAtLogin error: \(error)")
        }
    }

    enum PopupPosition: String {
        case atCursor       = "atCursor"
        case atPreviousPosition = "atPreviousPosition"

        var displayName: String {
            switch self {
            case .atCursor:           return "At Cursor"
            case .atPreviousPosition: return "At Previous Position"
            }
        }
    }
}
