import SwiftUI

struct CaptureSettingsView: View {
    @EnvironmentObject var vm: SettingsViewModel
    @State private var newAppBundleID = ""

    var body: some View {
        Form {
            Section("Content Types") {
                Toggle("Capture Images", isOn: $vm.captureImages)
                Toggle("Capture File Paths", isOn: $vm.captureFiles)
            }

            Section("Excluded Apps") {
                Text("Clipboard changes from these apps will be ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if vm.excludedApps.isEmpty {
                    Text("No excluded apps")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(vm.excludedApps, id: \.self) { bundleID in
                        HStack {
                            Image(nsImage: AppIconFetcher.shared.icon(for: bundleID))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(bundleID)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button {
                                vm.excludedApps.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    TextField("com.example.App", text: $newAppBundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Add") {
                        let id = newAppBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !id.isEmpty && !vm.excludedApps.contains(id) {
                            vm.excludedApps.append(id)
                            newAppBundleID = ""
                        }
                    }
                    .disabled(newAppBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button("Add Frontmost App") {
                    if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       !vm.excludedApps.contains(bundleID) {
                        vm.excludedApps.append(bundleID)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
