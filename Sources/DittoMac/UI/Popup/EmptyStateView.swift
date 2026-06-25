import SwiftUI

struct EmptyStateView: View {
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isFiltered ? "magnifyingglass" : "clipboard")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(isFiltered ? "No results" : "Nothing copied yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if !isFiltered {
                Text("Copy something to get started")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
