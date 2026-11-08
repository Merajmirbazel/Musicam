import Foundation
import Domain

/// What this device keeps downloaded. Per device: never synced (a phone and a Mac want different things).
public struct OfflineSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var keepFavorites = true
    public var playlists: Set<PlaylistID> = []
    /// Most space, in megabytes, that songs fetched from other devices may use. 0 means no limit.
    public var limitMegabytes = 0

    public init() {}

    public var limitBytes: Int64 { Int64(limitMegabytes) * 1_000_000 }
}

public struct OfflineSettingsStore {
    private let defaults: UserDefaults
    private let key = "musicam.offline"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> OfflineSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(OfflineSettings.self, from: $0) } ?? OfflineSettings()
    }

    public func save(_ settings: OfflineSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

/// A song file this device got from another device (and so can get again).
public struct FetchedFile: Sendable, Equatable {
    public var id: LibraryFileID
    public var size: Int64
    public var date: Date
    public init(id: LibraryFileID, size: Int64, date: Date) { self.id = id; self.size = size; self.date = date }
}

public struct OfflinePlan: Equatable, Sendable {
    public var toDownload: [Track]
    public var toEvict: [LibraryFileID]
    public var downloadBytes: Int64
}

/// Works out what to download and what may be removed. Pure, so it is easy to test.
public enum OfflinePlanner {
    public static func plan(settings: OfflineSettings, tracks: [Track], playlists: [Playlist],
                            present: Set<LibraryFileID>, fetched: [FetchedFile], now: Date = .now) -> OfflinePlan {
        guard settings.enabled else { return OfflinePlan(toDownload: [], toEvict: [], downloadBytes: 0) }

        // what should be here, most important first
        var ordered: [Track] = []
        if settings.keepFavorites { ordered += tracks.filter(\.isFavorite) }
        for p in playlists where settings.playlists.contains(p.id) { ordered += p.tracks(in: tracks) }

        var seen = Set<TrackID>()
        let limit = settings.limitBytes
        var budget = limit
        var wanted: [Track] = []
        var wantedFiles = Set<LibraryFileID>()
        for track in ordered where seen.insert(track.id).inserted {
            guard let file = track.file else { continue }
            if limit > 0 {
                guard file.byteSize <= budget else { continue }       // does not fit: try the next one
                budget -= file.byteSize
            }
            wanted.append(track)
            wantedFiles.insert(file.id)
        }
        let toDownload = wanted.filter { track in track.file.map { !present.contains($0.id) } ?? false }

        // only fetched copies are ever removed, and only when a limit is set and exceeded
        var evict: [LibraryFileID] = []
        if limit > 0 {
            let incoming = toDownload.reduce(Int64(0)) { $0 + ($1.file?.byteSize ?? 0) }
            var used = fetched.reduce(Int64(0)) { $0 + $1.size } + incoming
            for file in fetched.filter({ !wantedFiles.contains($0.id) }).sorted(by: { $0.date < $1.date }) where used > limit {
                evict.append(file.id)
                used -= file.size
            }
        }
        return OfflinePlan(toDownload: toDownload, toEvict: evict,
                           downloadBytes: toDownload.reduce(0) { $0 + ($1.file?.byteSize ?? 0) })
    }
}
