#if os(macOS)
import SwiftUI
import Domain

/// The library as a sortable table, with an info panel for the selected song.
struct SongsView: View {
    @Environment(AppModel.self) private var app
    @State private var sortOrder = [KeyPathComparator(\Track.addedAt, order: .reverse)]
    @State private var search = ""
    @State private var showInspector = true

    var body: some View {
        @Bindable var app = app
        let rows = app.library.visible(search: search, sortOrder: sortOrder)
        HStack(spacing: 0) {
            Table(rows, selection: $app.songSelection, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { track in
                    TitleCell(track: track)
                }
                .width(min: 180, ideal: 280)
                TableColumn("Artist", value: \.artist) { track in
                    Text(track.artist).foregroundStyle(.secondary)
                }
                TableColumn("Album", value: \.album) { track in
                    Text(track.album).foregroundStyle(.secondary)
                }
                TableColumn("Time", value: \.duration) { track in
                    Text(formatTime(track.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 60, max: 80)
                TableColumn("Source") { track in
                    if let file = track.file { SourceBadge(source: TrackSource(raw: file.source)) }
                }
                .width(min: 90, ideal: 120, max: 160)
                TableColumn("Format") { track in
                    Text(track.file?.format.codec ?? "").foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 64, max: 90)
            }
            .contextMenu(forSelectionType: Track.ID.self) { ids in
                TrackContextMenu(ids: ids, rows: rows) { remove($0) }
            } primaryAction: { ids in
                play(ids, in: rows)
            }
            .overlay {
                if app.library.isLoaded && app.library.tracks.isEmpty { EmptyLibraryView() }
                else if rows.isEmpty && app.library.isLoaded { ContentUnavailableView.search(text: search) }
            }

            if showInspector {
                Divider()
                TrackInspectorView(selection: app.songSelection)
                    .frame(width: 290)
                    .background(.background.secondary)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Songs")
        .toolbar {
            AddMusicToolbarItem()
            ToolbarItem(placement: .primaryAction) {
                Button("Info", systemImage: "sidebar.right", action: toggleInspector)
                    .help("Show or hide song info")
            }
        }
        .navigationTitle("Songs")
        .navigationSubtitle("\(rows.count) songs")
        .onDeleteCommand { remove(app.songSelection) }
    }

    private func play(_ ids: Set<Track.ID>, in rows: [Track]) {
        guard let first = rows.firstIndex(where: { ids.contains($0.id) }) else { return }
        app.play(rows, startAt: first)
    }

    private func toggleInspector() {
        showInspector.toggle()
    }

    /// Removes the songs from the library. Undo (ten seconds) brings them back. The selection is cleared first so the
    /// table never holds selected rows that are being deleted.
    private func remove(_ ids: Set<Track.ID>) {
        guard !ids.isEmpty else { return }
        let model = app                       // not read again later: the view may be rebuilt by then
        model.songSelection.subtract(ids)
        Task { @MainActor in
            await Task.yield()
            await model.library.remove(ids)
        }
    }
}
#endif
