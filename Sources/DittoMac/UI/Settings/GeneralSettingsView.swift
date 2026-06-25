import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var vm: SettingsViewModel

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Launch at Login", isOn: $vm.launchAtLogin)

                HStack {
                    Text("History Limit")
                    Spacer()
                    TextField("", value: $vm.historyLimit, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $vm.historyLimit, in: 50...10_000, step: 50)
                        .labelsHidden()
                }
                Text("Oldest non-pinned clips are auto-deleted. Pinned clips are never deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Popup") {
                Picker("Open At", selection: $vm.popupPosition) {
                    Text("Cursor Position").tag(SettingsViewModel.PopupPosition.atCursor)
                    Text("Previous Position").tag(SettingsViewModel.PopupPosition.atPreviousPosition)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
