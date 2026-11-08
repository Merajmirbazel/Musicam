import Foundation

public typealias PlaylistID = UUID

/// A named, ordered list of songs, like a folder you drop songs into.
public struct Playlist: Identifiable, Hashable, Sendable {
    public let id: PlaylistID
    public var name: String
    public var trackIDs: [TrackID]
    public var createdAt: Date

    public init(id: PlaylistID = UUID(), name: String, trackIDs: [TrackID] = [], createdAt: Date = .now) {
        self.id = id; self.name = name; self.trackIDs = trackIDs; self.createdAt = createdAt
    }

    /// The songs to show, resolved against the current library, in the list's order. Songs that were removed from the library drop out.
    public func tracks(in library: [Track]) -> [Track] {
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return trackIDs.compactMap { byID[$0] }
    }
}

/// How often a song was played on this device, and when it was last played. Never synced.
public struct PlayStat: Hashable, Sendable {
    public var count: Int
    public var lastPlayedAt: Date?
    public init(count: Int = 0, lastPlayedAt: Date? = nil) { self.count = count; self.lastPlayedAt = lastPlayedAt }
}
