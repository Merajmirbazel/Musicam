#if os(macOS)
import SwiftUI

struct WatchedFolderRow: View {
    @Environment(AppModel.self) private var app
    let entry: WatchedFolders.Entry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !entry.isAvailable {
                Label("Not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            Button("Stop watching", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
    }

    private func remove() {
        let path = entry.path
        Task { await app.watched.remove(path: path) }
    }
}
#endif
