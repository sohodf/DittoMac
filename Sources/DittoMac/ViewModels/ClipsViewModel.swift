import AppKit
import Combine

@MainActor
final class ClipsViewModel: ObservableObject {
    static let shared = ClipsViewModel()

    @Published var clips: [ClipboardEntry] = []
    @Published var searchText: String = "" {
        didSet { scheduleSearch() }
    }
    @Published var selectedID: Int64?
    @Published var isLoading = false

    private var searchTimer: Timer?

    func refresh() async {
        do {
            if searchText.isEmpty {
                clips = try await DatabaseManager.shared.fetchRecent()
            } else {
                clips = try await DatabaseManager.shared.search(searchText)
            }
            // Keep selection valid
            if let sel = selectedID, !clips.contains(where: { $0.id == sel }) {
                selectedID = clips.first?.id
            }
        } catch {
            print("ClipsViewModel refresh error: \(error)")
        }
    }

    private func scheduleSearch() {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: Selection helpers

    var selectedEntry: ClipboardEntry? {
        clips.first { $0.id == selectedID }
    }

    func selectFirst() {
        selectedID = clips.first?.id
    }

    func selectNext() {
        guard !clips.isEmpty else { return }
        if let current = selectedID, let idx = clips.firstIndex(where: { $0.id == current }) {
            selectedID = clips[min(idx + 1, clips.count - 1)].id
        } else {
            selectedID = clips.first?.id
        }
    }

    func selectPrevious() {
        guard !clips.isEmpty else { return }
        if let current = selectedID, let idx = clips.firstIndex(where: { $0.id == current }) {
            selectedID = clips[max(idx - 1, 0)].id
        } else {
            selectedID = clips.last?.id
        }
    }

    // MARK: Actions

    func togglePin(_ entry: ClipboardEntry) async {
        do {
            if entry.isPinned {
                try await DatabaseManager.shared.unpin(entry)
            } else {
                try await DatabaseManager.shared.pin(entry)
            }
            await refresh()
        } catch {
            print("Pin error: \(error)")
        }
    }

    func delete(_ entry: ClipboardEntry) async {
        do {
            try await DatabaseManager.shared.delete(entry)
            await refresh()
        } catch {
            print("Delete error: \(error)")
        }
    }

    // MARK: Grouped sections

    var pinnedClips: [ClipboardEntry] { clips.filter { $0.isPinned } }
    var recentClips: [ClipboardEntry] { clips.filter { !$0.isPinned } }
}
