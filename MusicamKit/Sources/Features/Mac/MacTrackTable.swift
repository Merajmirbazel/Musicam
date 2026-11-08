#if os(macOS)
import SwiftUI
import Domain

/// A table of songs for a playlist or Favorites, with real multi-select (click, Shift-click, Command-click, Command-A) and
/// batch actions on the whole selection. Inside a playlist, "Remove" takes songs out of the playlist only.
struct MacTrackTable: View {
    @Environment(AppModel.self) private var app
    let title: String
    let tracks: [Track]
    var playlist: Playlist?
    @State private var selection = Set<Track.ID>()
    @State private var newPlaylistFor: [Track.ID]?
    @State private var newName = ""

    var body: some View {
        // The toolbar and menus rebuild their content later, on their own; they must use this captured model,
        // never the view's @Environment property (reading that from a rebuilt toolbar item crashes).
        let model = app
        Table(tracks, selection: $selection) {
            TableColumn("") { track in
                Button { toggle(track.id) } label: {
                    Image(systemName: selection.contains(track.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(track.id) ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Select this song")
            }.width(26)
            TableColumn("Title") { track in TitleCell(track: track) }.width(min: 180, ideal: 280)
            TableColumn("Artist") { Text($0.artist).foregroundStyle(.secondary) }
            TableColumn("Album") { Text($0.album).foregroundStyle(.secondary) }
            TableColumn("Source") { track in
                if let file = track.file { SourceBadge(source: TrackSource(raw: file.source)) }
            }.width(min: 90, ideal: 120, max: 160)
            TableColumn("Time") { Text(formatTime($0.duration)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 50, ideal: 60, max: 80)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in menu(ids, model) } primaryAction: { ids in
            if let first = tracks.firstIndex(where: { ids.contains($0.id) }) { model.play(tracks, startAt: first) }
        }
        .onDeleteCommand { remove(selection, model) }
        .overlay { if tracks.isEmpty { empty } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { bulkBar(model) }
        }
        .toolbar {
            ToolbarItemGroup {
                if !selection.isEmpty {
                    Text("\(selection.count) songs selected").font(.callout).foregroundStyle(.secondary)
                    Button(playlist == nil ? "Remove" : "Remove from Playlist", systemImage: "trash") { remove(selection, model) }
                        .help("Remove the selected songs")
                    Menu("Add to Playlist", systemImage: "text.badge.plus") { addMenu(Array(selection), model) }
                    Button("Favorite", systemImage: "heart") { toggleFavorite(chosen(selection), model) }
                }
                Button("Play", systemImage: "play.fill") { if !tracks.isEmpty { model.play(tracks, startAt: 0) } }.disabled(tracks.isEmpty)
                Button("Shuffle", systemImage: "shuffle") { if !tracks.isEmpty { model.play(tracks.shuffled(), startAt: 0) } }.disabled(tracks.isEmpty)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(String(localized: "\(tracks.count) songs") + " · " + formatLongDuration(tracks.reduce(0) { $0 + $1.duration }))
        .alert("New Playlist", isPresented: Binding(get: { newPlaylistFor != nil }, set: { if !$0 { newPlaylistFor = nil } })) {
            TextField("Name", text: $newName)
            Button("Create") { let ids = newPlaylistFor ?? []; let n = newName; Task { await model.playlists.create(name: n, tracks: ids) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var empty: some View {
        if playlist != nil {
            ContentUnavailableView("Empty Playlist", systemImage: "music.note.list", description: Text("Right-click songs in Songs and choose Add to Playlist."))
        } else {
            ContentUnavailableView("No favorites yet", systemImage: "heart", description: Text("Right-click a song and choose Add to Favorites."))
        }
    }

    private func toggle(_ id: Track.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// The same actions as the toolbar, in plain sight under the table whenever songs are selected.
    private func bulkBar(_ app: AppModel) -> some View {
        HStack(spacing: 14) {
            Button(selection.count == tracks.count ? "Deselect All" : "Select All",
                   systemImage: selection.count == tracks.count ? "circle" : "checkmark.circle.fill") {
                selection = selection.count == tracks.count ? [] : Set(tracks.map(\.id))
            }
            Text("\(selection.count) songs selected").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Menu("Add to Playlist", systemImage: "text.badge.plus") { addMenu(Array(selection), app) }
            Button("Favorite", systemImage: "heart") { toggleFavorite(chosen(selection), app) }
            Button(playlist == nil ? "Remove" : "Remove from Playlist", systemImage: "trash", role: .destructive) { remove(selection, app) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func chosen(_ ids: Set<Track.ID>) -> [Track] { tracks.filter { ids.contains($0.id) } }

    @ViewBuilder private func menu(_ ids: Set<Track.ID>, _ app: AppModel) -> some View {
        let picked = chosen(ids)
        if !picked.isEmpty {
            Button("Play", systemImage: "play.fill") { if let i = tracks.firstIndex(of: picked[0]) { app.play(tracks, startAt: i) } }
            Button("Play Next", systemImage: "text.insert") { picked.reversed().forEach(app.playback.playNext) }
            Button("Add to Queue", systemImage: "text.append") { picked.forEach(app.playback.addToQueue) }
            Menu("Add to Playlist", systemImage: "text.badge.plus") { addMenu(Array(ids), app) }
            Button(picked.allSatisfy(\.isFavorite) ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") { toggleFavorite(picked, app) }
            if let playlist {
                Divider()
                Button("Move Up", systemImage: "arrow.up") { move(ids, in: playlist, by: -1, app) }
                Button("Move Down", systemImage: "arrow.down") { move(ids, in: playlist, by: 1, app) }
            }
            Divider()
            Button(playlist == nil ? "Remove from Library" : "Remove from Playlist", systemImage: "trash", role: .destructive) { remove(ids, app) }
        }
    }

    @ViewBuilder private func addMenu(_ ids: [Track.ID], _ app: AppModel) -> some View {
        ForEach(app.playlists.playlists) { list in
            Button(list.name, systemImage: "music.note.list") { Task { await app.playlists.add(ids, to: list.id) } }
        }
        Button("New Playlist…", systemImage: "plus") { newName = ""; newPlaylistFor = ids }
    }

    private func toggleFavorite(_ picked: [Track], _ app: AppModel) {
        let make = !picked.allSatisfy(\.isFavorite)
        Task { for t in picked { await app.library.edit(t.id, TrackEdit(isFavorite: make)) } }
    }

    /// Clears the selection first and removes on the next turn of the run loop, so the table is never asked to
    /// keep selected rows that are being deleted underneath it. The model is passed in (not read from the view's
    /// environment later): by then the view may already have been rebuilt, and reading its environment would crash.
    private func remove(_ ids: Set<Track.ID>, _ app: AppModel) {
        guard !ids.isEmpty else { return }
        selection = []
        let playlistID = playlist?.id
        Task { @MainActor in
            await Task.yield()
            if let playlistID { await app.playlists.remove(ids, from: playlistID) } else { await app.library.remove(ids) }
        }
    }

    private func move(_ ids: Set<Track.ID>, in list: Playlist, by delta: Int, _ app: AppModel) {
        let offsets = IndexSet(tracks.indices.filter { ids.contains(tracks[$0].id) })
        guard let first = offsets.first, let last = offsets.last else { return }
        let destination = delta < 0 ? max(first - 1, 0) : min(last + 2, tracks.count)
        Task { await app.playlists.move(in: list.id, from: offsets, to: destination) }
    }
}

struct MacPlaylistScreen: View {
    @Environment(AppModel.self) private var app
    let id: PlaylistID

    var body: some View {
        if let list = app.playlists.playlist(id: id) {
            MacTrackTable(title: list.name, tracks: app.playlists.tracks(of: list), playlist: list)
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "questionmark.folder")
        }
    }
}
#endif
