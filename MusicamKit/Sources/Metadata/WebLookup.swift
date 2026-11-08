import Foundation
import Domain

/// One song as a web catalog describes it.
struct CatalogEntry: Sendable {
    var title: String
    var artist: String
    var album: String?
    var year: Int?
    var cover: URL?
    var id: String
}

/// Turns a catalog's answer into matches, scoring how sure we are that it is the song we asked about.
/// A title-only search is only trusted when every result with that title agrees on the artist.
enum CatalogScoring {
    static func matches(for entries: [CatalogEntry], title: String, artist: String?) -> [MusicBrainzMatch] {
        let wantTitle = SearchNormalizer.normalize(title)
        let wantArtist = SearchNormalizer.normalize(artist ?? "")
        let sameTitle = entries.filter { SearchNormalizer.normalize($0.title) == wantTitle }
        let artistsForTitle = Set(sameTitle.map { SearchNormalizer.normalize($0.artist) })
        return entries.map { e in
            var score = 40
            if SearchNormalizer.normalize(e.title) == wantTitle {
                let got = SearchNormalizer.normalize(e.artist)
                if !wantArtist.isEmpty {
                    score = (got == wantArtist || got.contains(wantArtist) || wantArtist.contains(got)) ? 100 : 55
                } else {
                    score = artistsForTitle.count == 1 ? 90 : 60
                }
            }
            return MusicBrainzMatch(recordingID: e.id, title: e.title, artist: e.artist, album: e.album,
                                    releaseID: nil, year: e.year, score: score, coverURL: e.cover)
        }
    }
}

public enum WebLookupError: Error, Equatable { case badStatus(Int), badResponse }

private func fetchJSON(_ url: URL, session: URLSession) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw WebLookupError.badResponse }
    guard http.statusCode == 200 else { throw WebLookupError.badStatus(http.statusCode) }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WebLookupError.badResponse }
    return root
}

/// Apple Music's public search (itunes.apple.com/search). No account or key; it carries a lot of Persian music.
public final class ITunesClient: RecordingLookup {
    private let session: URLSession
    private let limiter: RateLimiter
    public init(session: URLSession = .shared, limiter: RateLimiter = RateLimiter(interval: .seconds(3))) {
        self.session = session; self.limiter = limiter
    }

    public func search(title: String, artist: String?) async throws -> [MusicBrainzMatch] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: [title, artist ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)),
                        .init(name: "media", value: "music"), .init(name: "entity", value: "song"), .init(name: "limit", value: "8")]
        try await limiter.wait()
        let root = try await fetchJSON(c.url!, session: session)
        return CatalogScoring.matches(for: Self.entries(root), title: title, artist: artist)
    }

    static func entries(_ root: [String: Any]) -> [CatalogEntry] {
        guard let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let title = r["trackName"] as? String, let artist = r["artistName"] as? String else { return nil }
            let art = (r["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            let year = (r["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }
            return CatalogEntry(title: title, artist: artist, album: r["collectionName"] as? String, year: year,
                                cover: art.flatMap(URL.init(string:)), id: String(describing: r["trackId"] ?? title))
        }
    }
}

/// Deezer's public search (api.deezer.com/search). No account or key.
public final class DeezerClient: RecordingLookup {
    private let session: URLSession
    private let limiter: RateLimiter
    public init(session: URLSession = .shared, limiter: RateLimiter = RateLimiter(interval: .milliseconds(300))) {
        self.session = session; self.limiter = limiter
    }

    public func search(title: String, artist: String?) async throws -> [MusicBrainzMatch] {
        var q = "track:\"\(title.replacingOccurrences(of: "\"", with: ""))\""
        if let artist, !artist.isEmpty { q += " artist:\"\(artist.replacingOccurrences(of: "\"", with: ""))\"" }
        var c = URLComponents(string: "https://api.deezer.com/search")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "limit", value: "8")]
        try await limiter.wait()
        let root = try await fetchJSON(c.url!, session: session)
        return CatalogScoring.matches(for: Self.entries(root), title: title, artist: artist)
    }

    static func entries(_ root: [String: Any]) -> [CatalogEntry] {
        guard let data = root["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { r in
            guard let title = r["title"] as? String, let artist = (r["artist"] as? [String: Any])?["name"] as? String else { return nil }
            let album = r["album"] as? [String: Any]
            let cover = (album?["cover_big"] as? String) ?? (album?["cover_medium"] as? String)
            return CatalogEntry(title: title, artist: artist, album: album?["title"] as? String, year: nil,
                                cover: cover.flatMap(URL.init(string:)), id: String(describing: r["id"] ?? title))
        }
    }
}

/// Asks Deezer first (fast), then Apple Music when Deezer has no confident answer.
public struct CompositeLookup: RecordingLookup {
    private let sources: [any RecordingLookup]
    public init(_ sources: [any RecordingLookup]) { self.sources = sources }
    public static func web() -> CompositeLookup { CompositeLookup([DeezerClient(), ITunesClient()]) }

    public func search(title: String, artist: String?) async throws -> [MusicBrainzMatch] {
        var best: [MusicBrainzMatch] = []
        var lastError: Error?
        var answered = false
        for source in sources {
            do {
                let found = try await source.search(title: title, artist: artist)
                answered = true
                if (found.map(\.score).max() ?? 0) >= 90 { return found }
                if best.isEmpty { best = found }
            } catch { lastError = error }
        }
        if !answered, let lastError { throw lastError }
        return best
    }
}

/// Search pages the person can open to look a song up by hand. Nothing is fetched or scraped by the app.
public enum WebSearchLinks {
    public struct Link: Identifiable, Sendable { public var id: String { name }; public let name: String; public let url: URL }

    public static func links(title: String, artist: String) -> [Link] {
        let q = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
        let encQuery = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return [
            Link(name: "Google", url: URL(string: "https://www.google.com/search?q=\(encQuery)")!),
            Link(name: "YouTube", url: URL(string: "https://www.youtube.com/results?search_query=\(encQuery)")!),
            Link(name: "Spotify", url: URL(string: "https://open.spotify.com/search/\(enc)")!),
        ]
    }
}
