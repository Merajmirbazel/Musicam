import Foundation
import Observation
import Domain
import Persistence
import Importing

/// What the library screens show and do. All database and import work happens in the stores; this only holds snapshots.
@MainActor
@Observable
public final class LibraryModel {
    public private(set) var tracks: [Track] = []
    public private(set) var isLoaded = false
    public private(set) var importState: ImportState = .idle

    /// Library files this device actually holds (the rest live only on a paired device).
    public private(set) var localFileIDs = Set<LibraryFileID>()
    /// When this device got each file it holds, and whether it was copied here from another device.
    public private(set) var acquired: [LibraryFileID: (date: Date, copiedFromDevice: Bool)] = [:]

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let device: DeviceStore
    @ObservationIgnored private let importer: ImportService
    @ObservationIgnored private let appFolder: URL?
    @ObservationIgnored private let mediaDirectory: URL?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    /// Called after a change made on this device, so paired devices can be told.
    @ObservationIgnored public var onLocalChange: (@MainActor () -> Void)?
    /// Offers Undo for removals.
    @ObservationIgnored public var undo: UndoCenter?

    /// `appFolder` is the app's own storage: files inside it were copied in by the app and may be deleted with their song;
    /// files anywhere else belong to the person and are never touched.
    public init(store: LibraryStore, device: DeviceStore, importer: ImportService, appFolder: URL? = nil, mediaDirectory: URL? = nil) {
        self.store = store
        self.device = device
        self.importer = importer
        self.appFolder = appFolder
        self.mediaDirectory = mediaDirectory
    }

    public func load() async {
        tracks = (try? await store.allTracks()) ?? []
        let entries = (try? await device.presentEntries()) ?? []
        localFileIDs = Set(entries.map(\.audioFileID))
        let media = mediaDirectory?.resolvingSymlinksInPath().path
        acquired = Dictionary(entries.map { e in
            (e.audioFileID, (date: e.acquiredAt ?? .distantPast,
                             copiedFromDevice: media.map { URL(fileURLWithPath: e.path).resolvingSymlinksInPath().path.hasPrefix($0 + "/") } ?? false))
        }, uniquingKeysWith: { a, _ in a })
        isLoaded = true
    }

    /// True when this device holds the song's audio file.
    public func isStoredHere(_ track: Track) -> Bool {
        track.file.map { localFileIDs.contains($0.id) } ?? false
    }

    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    public func track(id: TrackID) -> Track? {
        tracks.first { $0.id == id }
    }

    /// Imports files and folders in the background; the song list grows as batches land.
    /// `source` records where the files came from (see `TrackSource`); nil means picked by hand.
    public func startImport(_ urls: [URL], source: String? = nil, afterwards: (@MainActor () async -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        let previous = importTask
        importTask = Task { [weak self] in
            await previous?.value            // one import at a time
            guard let self else { return }
            for await event in importer.run(urls, source: source) {
                switch event {
                case .discovered(let total):
                    importState = .running(done: 0, total: total, name: "")
                case .progress(let done, let total, let name):
                    importState = .running(done: done, total: total, name: name)
                    if done % 200 == 0 { await load() }
                case .finished(let summary):
                    await mergeDuplicates()
                    await load()
                    importState = .finished(summary)
                    onLocalChange?()
                    await afterwards?()
                }
            }
        }
    }

    /// Folds together songs that two devices imported separately. Cheap to call after an import or a sync.
    public func mergeDuplicates() async {
        guard let merges = try? await store.mergeDuplicateTracks(), !merges.isEmpty else { return }
        for m in merges { try? await device.alias(winner: m.winner, loser: m.loser) }
        await load()
        onLocalChange?()
    }

    public func dismissImportMessage() {
        if case .finished = importState { importState = .idle }
    }

    public func edit(_ id: TrackID, _ edit: TrackEdit) async {
        guard let updated = try? await store.edit(trackID: id, edit),
              let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index] = updated
        onLocalChange?()
    }

    public func remove(_ ids: Set<TrackID>) async {
        let removed = tracks.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        try? await store.softDelete(trackIDs: removed.map(\.id))
        tracks.removeAll { ids.contains($0.id) }
        onLocalChange?()
        let removedIDs = removed.map(\.id)
        let fileIDs = removed.compactMap { $0.file?.id }
        let message = removed.count == 1 ? String(localized: "Removed “\(removed[0].title)”") : String(localized: "Removed \(removed.count) songs")
        guard let undo else { await purgeLocalFiles(fileIDs); return }
        undo.register(message,
                      undo: { [weak self] in await self?.restore(removedIDs) },
                      expire: { [weak self] in await self?.purgeLocalFiles(fileIDs) })
    }

    /// Undo for `remove`: the same songs come back, with their ratings and places in playlists.
    public func restore(_ ids: [TrackID]) async {
        try? await store.restore(trackIDs: ids)
        await load()
        onLocalChange?()
    }

    /// Once a removal is final: forget where the files were and delete the copies the app made itself (never the person's own files).
    private func purgeLocalFiles(_ fileIDs: [LibraryFileID]) async {
        let stillGone = ((try? await store.deletedFileIDs()) ?? []).intersection(fileIDs)     // not if the song was added again meanwhile
        let root = appFolder?.resolvingSymlinksInPath().path
        for id in stillGone {
            guard let entry = try? await device.entry(for: id) else { continue }
            if let root, URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path.hasPrefix(root + "/") {
                try? FileManager.default.removeItem(atPath: entry.path)
                // the folder made for an imported copy goes too, when it is empty
                let folder = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true, folder.path != root { try? FileManager.default.removeItem(at: folder) }
            }
        }
        try? await device.forget(Array(stillGone))
        await load()
    }

    /// At launch: deletes copies the app made itself (in its own Imported and Downloaded folders) that no song uses any
    /// more, for example when the app was closed during the Undo window. Files outside those folders are never touched.
    public func sweepOrphanedCopies() async {
        guard let appFolder else { return }
        let held = Set(((try? await device.presentEntries()) ?? []).map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        for name in ["Imported", "Downloaded"] {
            let folder = appFolder.appendingPathComponent(name, isDirectory: true)
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                let inside = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                let unused = inside.filter { !held.contains($0.resolvingSymlinksInPath().path) }
                for file in unused { try? FileManager.default.removeItem(at: file) }
                if unused.count == inside.count { try? FileManager.default.removeItem(at: item) }       // nothing in the folder is used
            }
        }
    }

    /// Songs that match the search, best match first. Works the same for Persian, Arabic and Latin text.
    public func search(_ query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tracks }
        return tracks.filter { SearchNormalizer.matches(q, in: [$0.title, $0.artist, $0.album]) }
            .map { ($0, SearchNormalizer.score(q, title: $0.title, artist: $0.artist, album: $0.album)) }
            .sorted { ($0.1, $1.0.title) > ($1.1, $0.0.title) }.map(\.0)
    }

    /// The rows to show: filtered by the search text, then sorted.
    public func visible(search: String, sortOrder: [KeyPathComparator<Track>]) -> [Track] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? tracks : tracks.filter { SearchNormalizer.matches(query, in: [$0.title, $0.artist, $0.album]) }
        return filtered.sorted(using: sortOrder)
    }

    /// The most recently added songs, newest first.
    public func recentlyAdded(limit: Int) -> [Track] {
        Array(tracks.sorted { $0.addedAt > $1.addedAt }.prefix(limit))
    }

    /// Songs that reached this device from outside: copied from another device, or downloaded or handed over by a link,
    /// Telegram, a watched folder or another app. Newest first. Songs picked by hand are not "downloaded".
    public func recentlyDownloaded(limit: Int) -> [Track] {
        tracks.compactMap { t -> (Track, Date)? in
            guard let file = t.file, let got = acquired[file.id] else { return nil }
            guard got.copiedFromDevice || TrackSource(raw: file.source).isDownloaded else { return nil }
            return (t, got.date)
        }
        .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
