#if os(macOS)
import SwiftUI
import Domain

/// Right-click menu for one or more songs.
struct TrackContextMenu: View {
    @Environment(AppModel.self) private var app
    let ids: Set<Track.ID>
    let rows: [Track]
    let requestRemoval: (Set<Track.ID>) -> Void

    var body: some View {
        let chosen = rows.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Play", systemImage: "play.fill") { play(chosen) }
            Button("Play Next", systemImage: "text.insert") { chosen.reversed().forEach(app.playback.playNext) }
            Button("Add to Queue", systemImage: "text.append") { chosen.forEach(app.playback.addToQueue) }
            Divider()
            Menu("Add to Playlist", systemImage: "music.note.list") {
                ForEach(app.playlists.playlists) { list in
                    Button(list.name) { Task { await app.playlists.add(chosen.map(\.id), to: list.id) } }
                }
                if !app.playlists.playlists.isEmpty { Divider() }
                Button("New Playlist…", systemImage: "plus") {
                    let ids = chosen.map(\.id)
                    Task { if let made = await app.playlists.create(name: "New Playlist", tracks: ids) { app.section = .playlist(made.id) } }
                }
            }
            Divider()
            Button(allFavourite(chosen) ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") { toggleFavourite(chosen) }
            Divider()
            Button("Remove from Library", systemImage: "trash", role: .destructive) { requestRemoval(ids) }
        }
    }

    private func play(_ chosen: [Track]) {
        app.play(chosen, startAt: 0)
    }

    private func allFavourite(_ chosen: [Track]) -> Bool {
        chosen.allSatisfy(\.isFavorite)
    }

    private func toggleFavourite(_ chosen: [Track]) {
        let makeFavourite = !allFavourite(chosen)
        Task {
            for track in chosen { await app.library.edit(track.id, TrackEdit(isFavorite: makeFavourite)) }
        }
    }
}
#endif
