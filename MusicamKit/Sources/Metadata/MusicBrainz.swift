import Foundation
import Domain

public struct MusicBrainzMatch: Hashable, Sendable {
    public var recordingID: String
    public var title: String
    public var artist: String
    public var album: String?
    public var releaseID: String?
    public var year: Int?
    /// MusicBrainz's own 0...100 score.
    public var score: Int
    /// A direct link to the cover picture, when the catalog gives one.
    public var coverURL: URL?

    public init(recordingID: String, title: String, artist: String, album: String? = nil, releaseID: String? = nil, year: Int? = nil, score: Int, coverURL: URL? = nil) {
        self.recordingID = recordingID; self.title = title; self.artist = artist; self.album = album
        self.releaseID = releaseID; self.year = year; self.score = score; self.coverURL = coverURL
    }
}

public protocol RecordingLookup: Sendable {
    func search(title: String, artist: String?) async throws -> [MusicBrainzMatch]
}

/// Lets only one request per interval through (MusicBrainz asks for at most one per second).
public actor RateLimiter {
    private let interval: Duration
    private var next: ContinuousClock.Instant = .now
    public init(interval: Duration = .seconds(1)) { self.interval = interval }
    public func wait() async throws {
        let now = ContinuousClock.now
        let slot = max(now, next)
        next = slot.advanced(by: interval)
        if slot > now { try await Task.sleep(until: slot, clock: .continuous) }
    }
}

public enum MusicBrainzError: Error, Equatable { case badStatus(Int), badResponse }

/// Searches musicbrainz.org by title and artist. Identifies itself with a User-Agent as the service requires.
public final class MusicBrainzClient: RecordingLookup {
    private let session: URLSession
    private let limiter: RateLimiter
    private let userAgent: String
    private let baseURL: URL

    public init(contact: String? = nil, session: URLSession = .shared, limiter: RateLimiter = RateLimiter(),
                baseURL: URL = URL(string: "https://musicbrainz.org/ws/2")!) {
        self.session = session
        self.limiter = limiter
        self.baseURL = baseURL
        self.userAgent = contact.map { "Musicam/0.4 ( \($0) )" } ?? "Musicam/0.4"
    }

    public func search(title: String, artist: String?) async throws -> [MusicBrainzMatch] {
        var query = "recording:\"\(escape(title))\""
        if let artist, !artist.isEmpty { query += " AND artist:\"\(escape(artist))\"" }
        var components = URLComponents(url: baseURL.appendingPathComponent("recording"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "query", value: query), .init(name: "fmt", value: "json"), .init(name: "limit", value: "5")]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        try await limiter.wait()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicBrainzError.badResponse }
        guard http.statusCode == 200 else { throw MusicBrainzError.badStatus(http.statusCode) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [MusicBrainzMatch] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = root["recordings"] as? [[String: Any]] else { throw MusicBrainzError.badResponse }
        return recordings.compactMap { r in
            guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
            let credits = r["artist-credit"] as? [[String: Any]] ?? []
            let artist = credits.compactMap { $0["name"] as? String }.joined(separator: ", ")
            let releases = r["releases"] as? [[String: Any]] ?? []
            let release = releases.first
            let date = release?["date"] as? String
            let year = date.flatMap { Int($0.prefix(4)) }
            return MusicBrainzMatch(recordingID: id, title: title, artist: artist, album: release?["title"] as? String,
                                    releaseID: release?["id"] as? String, year: year, score: (r["score"] as? Int) ?? 0)
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Cover Art Archive front cover for a release. Returns nil when there is none.
public struct CoverArtClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func frontCover(releaseID: String) async -> Data? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front-500") else { return nil }
        return await image(at: url)
    }

    /// Downloads a cover picture from a link (a catalog's cover, or a Cover Art Archive release).
    public func image(at url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }
}

/// Turns a lookup result into a reviewable suggestion, only when it clearly matches what the song already says.
public enum MusicBrainzPlanner {
    /// The release to take a cover from, when the best match clearly is this song.
    public static func coverRelease(for track: Track, matches: [MusicBrainzMatch]) -> String? {
        guard let best = matches.max(by: { $0.score < $1.score }), best.score >= 90,
              TagSanity.normalize(best.title) == TagSanity.normalize(track.title) else { return nil }
        return best.coverURL?.absoluteString ?? best.releaseID
    }

    public static func proposal(for track: Track, matches: [MusicBrainzMatch]) -> RepairProposal? {
        guard let best = matches.max(by: { $0.score < $1.score }), best.score >= 90 else { return nil }
        // the match must agree with the title we already have; otherwise it is a different song
        guard TagSanity.normalize(best.title) == TagSanity.normalize(track.title) else { return nil }
        var changes: [FieldChange] = []
        func add(_ field: RepairField, _ before: String, _ after: String?) {
            guard let after, !after.isEmpty, after != before else { return }
            changes.append(FieldChange(field: field, before: before, after: after, reason: .fromMusicBrainz))
        }
        // fill blanks, and fix spelling differences only in case/spacing; never replace a different artist
        if track.artist.isEmpty { add(.artist, track.artist, best.artist) }
        else if TagSanity.normalize(track.artist) == TagSanity.normalize(best.artist) { add(.artist, track.artist, best.artist) }
        if track.album.isEmpty { add(.album, track.album, best.album) }
        add(.title, track.title, TagSanity.normalize(track.title) == TagSanity.normalize(best.title) ? best.title : nil)
        guard !changes.isEmpty else { return nil }
        var confidence = Double(best.score) / 100 * 0.95
        // a title-only match could be another artist's song with the same name: always ask the person to check
        if track.artist.isEmpty { confidence = min(confidence, 0.8) }
        return RepairProposal(trackID: track.id, changes: changes, confidence: confidence)
    }
}
