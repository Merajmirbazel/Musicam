import Foundation

public typealias TrackID = UUID
public typealias LibraryFileID = UUID
public typealias DeviceID = UUID

/// Technical description of an audio file's encoding.
public struct AudioFormat: Hashable, Sendable, Codable {
    public var codec: String          // "FLAC", "MP3", "AAC", "ALAC", "WAV" ...
    public var sampleRate: Double
    public var bitDepth: Int?         // nil for lossy codecs
    public var channels: Int
    public var bitrate: Int?          // bits per second, when known
    public var isLossless: Bool

    public init(codec: String, sampleRate: Double = 0, bitDepth: Int? = nil, channels: Int = 0, bitrate: Int? = nil, isLossless: Bool = false) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.bitrate = bitrate
        self.isLossless = isLossless
    }

    /// For example "FLAC · 24-bit · 96 kHz" or "MP3 · 320 kbps".
    public var summary: String {
        var parts = [codec]
        if isLossless {
            if let bitDepth { parts.append("\(bitDepth)-bit") }
            if sampleRate > 0 { parts.append(Self.kilohertz(sampleRate)) }
        } else if let bitrate, bitrate > 0 {
            parts.append("\(bitrate / 1000) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private static func kilohertz(_ hz: Double) -> String {
        let k = hz / 1000
        return (k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)) + " kHz"
    }
}

/// One physical audio file. A track can have several (see architecture, section 3).
public struct AudioFileInfo: Identifiable, Hashable, Sendable, Codable {
    public let id: LibraryFileID
    public var contentHash: String        // SHA-256, lowercase hex
    public var byteSize: Int64
    public var originalFilename: String
    public var format: AudioFormat
    public var duration: TimeInterval
    /// See `TrackSource`; empty for files added before sources were recorded.
    public var source: String

    public init(id: LibraryFileID = UUID(), contentHash: String, byteSize: Int64, originalFilename: String, format: AudioFormat, duration: TimeInterval, source: String = "") {
        self.source = source
        self.id = id
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.originalFilename = originalFilename
        self.format = format
        self.duration = duration
    }
}

/// A track is a stable identity; this is an immutable snapshot of it that is safe to hand to the UI.
public struct Track: Identifiable, Hashable, Sendable, Codable {
    public let id: TrackID
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String
    public var rating: Int                 // 0 to 5
    public var isFavorite: Bool
    public var addedAt: Date
    public var duration: TimeInterval
    public var artworkKey: String?         // hash of the cached cover image
    public var file: AudioFileInfo?        // the primary file

    public init(id: TrackID = UUID(), title: String, artist: String = "", album: String = "", albumArtist: String = "",
                trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil, genre: String = "",
                rating: Int = 0, isFavorite: Bool = false, addedAt: Date = .now, duration: TimeInterval = 0,
                artworkKey: String? = nil, file: AudioFileInfo? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.rating = rating
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.duration = duration
        self.artworkKey = artworkKey
        self.file = file
    }
}

/// What the tag reader found in a file.
public struct ExtractedMetadata: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String
    public var duration: TimeInterval
    public var format: AudioFormat
    public var artworkKey: String?

    public init(title: String, artist: String = "", album: String = "", albumArtist: String = "", trackNumber: Int? = nil,
                discNumber: Int? = nil, year: Int? = nil, genre: String = "", duration: TimeInterval = 0,
                format: AudioFormat, artworkKey: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.duration = duration
        self.format = format
        self.artworkKey = artworkKey
    }
}

/// A file that has been hashed and read, ready to be added to the library.
public struct ImportedItem: Sendable {
    public var metadata: ExtractedMetadata
    public var contentHash: String
    public var byteSize: Int64
    public var originalFilename: String
    public var source: String

    public init(metadata: ExtractedMetadata, contentHash: String, byteSize: Int64, originalFilename: String, source: String = "") {
        self.source = source
        self.metadata = metadata
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.originalFilename = originalFilename
    }
}

/// Changes a user can make to a track's tags (all optional; nil leaves the field alone).
public struct TrackEdit: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var rating: Int?
    public var isFavorite: Bool?
    /// Key of a cover in the artwork store; an empty string removes the cover.
    public var artworkKey: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, rating: Int? = nil, isFavorite: Bool? = nil, artworkKey: String? = nil) {
        self.artworkKey = artworkKey
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist
        self.genre = genre; self.rating = rating; self.isFavorite = isFavorite
    }
}
