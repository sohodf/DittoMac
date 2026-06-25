import SwiftUI

struct MainView: View {
    @EnvironmentObject var vm: ClipsViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchBarView(text: $vm.searchText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            if vm.clips.isEmpty {
                EmptyStateView(isFiltered: !vm.searchText.isEmpty)
            } else {
                clipList
            }

            Divider()
            statusBar
        }
        .frame(width: 420, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !vm.pinnedClips.isEmpty {
                        Section {
                            ForEach(vm.pinnedClips) { entry in
                                ClipRowView(entry: entry)
                                    .id(entry.id)
                            }
                        } header: {
                            sectionHeader("Pinned", icon: "pin.fill")
                        }
                    }

                    if !vm.recentClips.isEmpty {
                        Section {
                            ForEach(vm.recentClips) { entry in
                                ClipRowView(entry: entry)
                                    .id(entry.id)
                            }
                        } header: {
                            sectionHeader("Recent", icon: "clock")
                        }
                    }
                }
            }
            .onChange(of: vm.selectedID) { newID in
                if let id = newID {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.regularMaterial)
    }

    private var statusBar: some View {
        HStack {
            Text("\(vm.clips.count) clip\(vm.clips.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(DatabaseManager.shared.databaseSize)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
