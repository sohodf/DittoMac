import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: SettingsViewModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            CaptureSettingsView()
                .tabItem { Label("Capture", systemImage: "doc.on.clipboard") }

            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
        }
        .frame(width: 540, height: 420)
    }
}
