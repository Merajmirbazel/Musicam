import SwiftUI
import Metadata

/// "Search online": looks on the Internet Archive for songs that can legally be downloaded, and adds the chosen file
/// to the library. It only runs when the person taps the button.
struct OnlineSearchSection: View {
    @Environment(AppModel.self) private var app
    let query: String
    @State private var opened: ArchiveItem?

    var body: some View {
        let online = app.online
        Section {
            if online.searchedFor != query {
                Button { Task { await online.search(query) } } label: {
                    Label("Search online for “\(query)”", systemImage: "globe")
                }
                .disabled(online.isSearching)
            }
            if online.isSearching { HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) } }
            if online.searchedFor == query {
                ForEach(online.items) { item in
                    Button { opened = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(2)
                                if !item.creator.isEmpty { Text(item.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let m = online.message, !online.isLoadingFiles { Text(m).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("Online")
        } footer: {
            Text("Searches the Internet Archive, a free library of public-domain and openly licensed music. Songs from streaming services are not available here.")
        }
        .sheet(item: $opened) { item in OnlineItemSheet(item: item) }
    }
}

/// The audio files of one Internet Archive item, each with a Download button.
struct OnlineItemSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: ArchiveItem

    var body: some View {
        let online = app.online
        NavigationStack {
            List {
                if online.isLoadingFiles { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
                ForEach(online.files) { file in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.title).lineLimit(2)
                            if file.size > 0 { Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if online.added.contains(file.id) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if online.downloading.contains(file.id) {
                            ProgressView()
                        } else {
                            Button("Download", systemImage: "arrow.down.circle.fill") { Task { await online.get(file) } }
                                .labelStyle(.iconOnly).font(.title2)
                        }
                    }
                }
                if let m = online.message { Text(m).font(.callout).foregroundStyle(.secondary) }
            }
            .navigationTitle(item.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .task { await online.loadFiles(of: item) }
    }
}
