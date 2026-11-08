import Foundation
import SwiftData
import Domain
import Sync

// SwiftData models stay inside this module and inside their store actors.
// Everything that leaves a store is an immutable Domain value.

@Model
final class TrackRecord {
    #Index<TrackRecord>([\.addedAt], [\.title])

    var id: UUID = UUID()
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var albumArtist: String = ""
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String = ""
    var rating: Int = 0
    var isFavorite: Bool = false
    var addedAt: Date = Date.now
    var updatedAt: Date = Date.now
    var duration: Double = 0
    var artworkKey: String?
    var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \AudioFileRecord.track)
    var files: [AudioFileRecord]? = []

    init(id: UUID = UUID(), metadata: ExtractedMetadata, addedAt: Date = .now) {
        self.id = id
        self.title = metadata.title
        self.artist = metadata.artist
        self.album = metadata.album
        self.albumArtist = metadata.albumArtist
        self.trackNumber = metadata.trackNumber
        self.discNumber = metadata.discNumber
        self.year = metadata.year
        self.genre = metadata.genre
        self.duration = metadata.duration
        self.artworkKey = metadata.artworkKey
        self.addedAt = addedAt
        self.updatedAt = addedAt
    }
}

@Model
final class AudioFileRecord {
    #Index<AudioFileRecord>([\.contentHash])

    var id: UUID = UUID()
    var contentHash: String = ""
    var byteSize: Int64 = 0
    var originalFilename: String = ""
    var codec: String = ""
    var sampleRate: Double = 0
    var bitDepth: Int?
    var channels: Int = 0
    var bitrate: Int?
    var isLossless: Bool = false
    var duration: Double = 0
    var source: String = ""
    var track: TrackRecord?

    init(id: UUID = UUID(), item: ImportedItem) {
        self.id = id
        self.contentHash = item.contentHash
        self.byteSize = item.byteSize
        self.originalFilename = item.originalFilename
        self.codec = item.metadata.format.codec
        self.sampleRate = item.metadata.format.sampleRate
        self.bitDepth = item.metadata.format.bitDepth
        self.channels = item.metadata.format.channels
        self.bitrate = item.metadata.format.bitrate
        self.isLossless = item.metadata.format.isLossless
        self.duration = item.metadata.duration
        self.source = item.source
    }

    var info: AudioFileInfo {
        AudioFileInfo(id: id, contentHash: contentHash, byteSize: byteSize, originalFilename: originalFilename,
                      format: AudioFormat(codec: codec, sampleRate: sampleRate, bitDepth: bitDepth, channels: channels,
                                          bitrate: bitrate, isLossless: isLossless),
                      duration: duration, source: source)
    }
}

/// Where a library file lives on THIS device. Never synced.
@Model
final class LocalFileRecord {
    var audioFileID: UUID = UUID()
    var bookmark: Data = Data()
    var path: String = ""
    var byteSize: Int64 = 0
    var modificationDate: Date?
    var state: String = LocalFileState.present.rawValue
    var verifiedAt: Date = Date.now
    /// When this device first got the file (nil for entries made before this was recorded).
    var acquiredAt: Date?

    init(info: LocalFileInfo) {
        self.audioFileID = info.audioFileID
        self.bookmark = info.bookmark
        self.path = info.path
        self.byteSize = info.byteSize
        self.modificationDate = info.modificationDate
        self.state = info.state.rawValue
        self.acquiredAt = info.acquiredAt
    }
}

extension TrackRecord {
    var snapshot: Track {
        Track(id: id, title: title, artist: artist, album: album, albumArtist: albumArtist, trackNumber: trackNumber,
              discNumber: discNumber, year: year, genre: genre, rating: rating, isFavorite: isFavorite, addedAt: addedAt,
              duration: duration, artworkKey: artworkKey, file: files?.first?.info)
    }
}

/// One immutable change, kept forever so it can be sent to any device that has not seen it yet.
@Model
final class ChangeRecord {
    #Index<ChangeRecord>([\.entityID], [\.deviceID, \.wall, \.counter])

    var wall: Int64 = 0
    var counter: Int64 = 0
    var deviceID: UUID = UUID()
    var entityName: String = ""
    var entityID: UUID = UUID()
    var field: String = ""
    var valueData: Data = Data()

    init(entry: ChangeEntry) {
        wall = Int64(bitPattern: entry.stamp.wallMillis)
        counter = Int64(entry.stamp.counter)
        deviceID = entry.stamp.device
        entityName = entry.key.entity
        entityID = entry.key.id
        field = entry.field
        valueData = (try? JSONEncoder().encode(entry.value)) ?? Data()
    }

    var stamp: HLCTimestamp {
        HLCTimestamp(wallMillis: UInt64(bitPattern: wall), counter: UInt32(truncatingIfNeeded: counter), device: deviceID)
    }

    var entry: ChangeEntry {
        let value = (try? JSONDecoder().decode(ChangeValue.self, from: valueData)) ?? .null
        return ChangeEntry(key: EntityKey(entity: entityName, id: entityID), field: field, value: value, stamp: stamp)
    }
}

/// One row per library file: this device's permanent identity in the sync network.
@Model
final class StoreMeta {
    var deviceID: UUID = UUID()
    init() {}
}

/// A folder this device keeps an eye on for new music. Never synced.
@Model
final class WatchedFolderRecord {
    var path: String = ""
    var bookmark: Data = Data()
    var addedAt: Date = Date.now

    init(path: String, bookmark: Data) {
        self.path = path
        self.bookmark = bookmark
    }
}

@Model
final class PlaylistRecord {
    var id: UUID = UUID()
    var name: String = ""
    /// Song IDs in order, comma-separated: one field, so the newest edit of the order wins.
    var trackIDs: String = ""
    /// Left over from the removed smart playlists. A playlist with rules is hidden, never deleted.
    var rules: String = ""
    var createdAt: Date = Date.now
    var deletedAt: Date?

    init(id: UUID) { self.id = id }

    var snapshot: Playlist {
        Playlist(id: id, name: name, trackIDs: Self.parse(trackIDs), createdAt: createdAt)
    }

    static func parse(_ s: String) -> [UUID] { s.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
    static func join(_ ids: [UUID]) -> String { ids.map(\.uuidString).joined(separator: ",") }
}

/// How often a song was played on this device. Never synced.
@Model
final class PlayStatRecord {
    var trackID: UUID = UUID()
    var count: Int = 0
    var lastPlayedAt: Date?

    init(trackID: UUID) { self.trackID = trackID }
}
