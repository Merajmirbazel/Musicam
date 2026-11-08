import Foundation

public enum SpotifyKind: String, Sendable, Codable {
    case track, playlist, album
}

public struct SpotifyLink: Sendable, Equatable, Codable {
    public let kind: SpotifyKind
    public let id: String
    public init(kind: SpotifyKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

public struct PlaylistInfo: Sendable, Codable, Equatable {
    public var name: String
    public var owner: String?
    public var description: String?
    public var coverURL: String?
    public var trackCount: Int?
    public init(name: String, owner: String? = nil, description: String? = nil,
                coverURL: String? = nil, trackCount: Int? = nil) {
        self.name = name
        self.owner = owner
        self.description = description
        self.coverURL = coverURL
        self.trackCount = trackCount
    }
}

public struct TrackInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var artists: String
    public var album: String?
    public var releaseDate: String?
    public var coverURL: String?
    public var durationMs: Int?
    public var previewURL: String?
    /// 1-based position in the playlist as Spotify presents it.
    public var position: Int?

    public init(id: String, title: String, artists: String, album: String? = nil,
                releaseDate: String? = nil, coverURL: String? = nil, durationMs: Int? = nil,
                previewURL: String? = nil, position: Int? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.releaseDate = releaseDate
        self.coverURL = coverURL
        self.durationMs = durationMs
        self.previewURL = previewURL
        self.position = position
    }
}

public enum MerajError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    /// Connectivity problem; retryable.
    case network(String)
    case rateLimited
    /// Page structure unexpected; not retryable.
    case extraction(String)
    /// Private, removed, or region-locked item.
    case unavailable(String)
    case toolMissing(String)
    case noMatch(String)
    case downloadFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return s
        case .network(let s): return "Network error: \(s)"
        case .rateLimited: return "Rate limited by Spotify - please wait before retrying"
        case .extraction(let s): return s
        case .unavailable(let s): return s
        case .toolMissing(let s): return s
        case .noMatch(let s): return s
        case .downloadFailed(let s): return s
        case .cancelled: return "Cancelled"
        }
    }
}

public enum AudioFormat: String, Sendable, Codable, CaseIterable {
    case mp3, m4a, opus, flac, wav

    public var ext: String { rawValue }
    public var isLossy: Bool { self == .mp3 || self == .m4a || self == .opus }
    public static let qualities = ["128", "192", "256", "320"]
}

public struct DownloadOptions: Sendable, Codable, Equatable {
    public var format: AudioFormat
    public var quality: String
    public var includeTrackNumber: Bool
    public var artistFirst: Bool
    public var titleOnly: Bool
    public var looseMatch: Bool
    public var cookiesFile: String?

    public init(format: AudioFormat = .mp3, quality: String = "192", includeTrackNumber: Bool = false,
                artistFirst: Bool = false, titleOnly: Bool = false, looseMatch: Bool = false,
                cookiesFile: String? = nil) {
        self.format = format
        self.quality = AudioFormat.qualities.contains(quality) ? quality : "192"
        self.includeTrackNumber = includeTrackNumber
        self.artistFirst = artistFirst
        self.titleOnly = titleOnly
        self.looseMatch = looseMatch
        self.cookiesFile = cookiesFile
    }
}
