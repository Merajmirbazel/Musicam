import Foundation
import Observation
import Domain
import Persistence

/// Playlists the person made: simple named lists of songs, like folders. Songs are always resolved against the current library.
@MainActor
@Observable
public final class PlaylistModel {
    public private(set) var playlists: [Playlist] = []

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored public var onLocalChange: (@MainActor () -> Void)?
    /// Offers Undo for removals.
    @ObservationIgnored public var undo: UndoCenter?

    public init(store: LibraryStore, library: LibraryModel) {
        self.store = store
        self.library = library
    }

    public func load() async {
        playlists = (try? await store.allPlaylists()) ?? []
    }

    public func playlist(id: PlaylistID) -> Playlist? { playlists.first { $0.id == id } }

    public func tracks(of playlist: Playlist) -> [Track] { playlist.tracks(in: library.tracks) }

    /// "12 songs · 48 min 10 sec": how many songs a playlist holds and how long they play in total.
    public func summary(of playlist: Playlist) -> String {
        let tracks = self.tracks(of: playlist)
        return String(localized: "\(tracks.count) songs") + " · " + formatLongDuration(tracks.reduce(0) { $0 + $1.duration })
    }

    /// Favorites are not a playlist you maintain: they are every song marked with the heart.
    public var favorites: [Track] { library.tracks.filter(\.isFavorite).sorted { $0.addedAt > $1.addedAt } }

    @discardableResult
    public func create(name: String, tracks: [Track.ID] = []) async -> Playlist? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let made = try? await store.createPlaylist(name: clean, trackIDs: tracks)
        await changed()
        return made
    }

    public func rename(_ id: PlaylistID, to name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        _ = try? await store.updatePlaylist(id, name: clean)
        await changed()
    }

    public func delete(_ id: PlaylistID) async {
        let name = playlist(id: id)?.name ?? ""
        try? await store.deletePlaylist(id)
        await changed()
        undo?.register(String(localized: "Deleted playlist “\(name)”"), undo: { [weak self] in
            try? await self?.store.restorePlaylist(id)
            await self?.changed()
        })
    }

    /// Adds songs to the end of a playlist; songs already in it are skipped. Returns how many were added.
    @discardableResult
    public func add(_ ids: [Track.ID], to id: PlaylistID) async -> Int {
        guard let list = playlist(id: id) else { return 0 }
        var seen = Set(list.trackIDs)
        let fresh = ids.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return 0 }
        _ = try? await store.updatePlaylist(id, trackIDs: list.trackIDs + fresh)
        await changed()
        return fresh.count
    }

    /// Takes songs out of a playlist (not out of the library). One Undo restores them in their places.
    public func remove(_ ids: Set<Track.ID>, from id: PlaylistID) async {
        guard let list = playlist(id: id) else { return }
        let before = list.trackIDs
        let after = before.filter { !ids.contains($0) }
        guard after.count != before.count else { return }
        _ = try? await store.updatePlaylist(id, trackIDs: after)
        await changed()
        let count = before.count - after.count
        undo?.register(count == 1 ? String(localized: "Removed 1 song from “\(list.name)”") : String(localized: "Removed \(count) songs from “\(list.name)”"),
                       undo: { [weak self] in
            _ = try? await self?.store.updatePlaylist(id, trackIDs: before)
            await self?.changed()
        })
    }

    public func move(in id: PlaylistID, from offsets: IndexSet, to destination: Int) async {
        guard let list = playlist(id: id) else { return }
        var order = list.trackIDs
        let moving = offsets.sorted().map { order[$0] }
        for index in offsets.sorted().reversed() { order.remove(at: index) }
        let shift = offsets.filter { $0 < destination }.count
        order.insert(contentsOf: moving, at: min(max(destination - shift, 0), order.count))
        _ = try? await store.updatePlaylist(id, trackIDs: order)
        await changed()
    }

    private func changed() async {
        await load()
        onLocalChange?()
    }
}
