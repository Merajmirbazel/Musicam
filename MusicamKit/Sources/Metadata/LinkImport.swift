import Foundation

/// What a pasted link points to. Musicam never downloads from streaming services; it only reads the public name
/// shown on their page (to remember what you want), or downloads a plain audio file you were given a direct link to.
public enum LinkKind: Equatable, Sendable {
    case spotify(url: URL)
    case youtube(url: URL)
    /// A link straight to an audio file, for example one you bought or one from the Internet Archive.
    case directAudio(url: URL)
    /// A streaming or store page we cannot take audio from.
    case unsupportedService(host: String)
    case notALink
}

public enum LinkParser {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac"]
    static let spotifyHosts = ["open.spotify.com", "spotify.link", "spotify.com"]
    static let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]
    static let otherServices = ["deezer.com", "soundcloud.com", "music.apple.com", "tidal.com", "napster.com", "pandora.com",
                                "amazon.com", "music.amazon.com", "bandcamp.com", "qobuz.com"]

    public static func classify(_ text: String) -> LinkKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("spotify:"), let url = URL(string: spotifyURI(trimmed)) { return .spotify(url: url) }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return .notALink }
        if spotifyHosts.contains(host) { return .spotify(url: url) }
        if youtubeHosts.contains(host) { return .youtube(url: url) }
        if let service = otherServices.first(where: { host == $0 || host.hasSuffix("." + $0) }) {
            // a plain file hosted there (for example a bought download link) is still fine
            if audioExtensions.contains(url.pathExtension.lowercased()) { return .directAudio(url: url) }
            return .unsupportedService(host: service)
        }
        if audioExtensions.contains(url.pathExtension.lowercased()) { return .directAudio(url: url) }
        return .notALink
    }

    /// "spotify:track:ID" -> "https://open.spotify.com/track/ID"
    static func spotifyURI(_ uri: String) -> String {
        let parts = uri.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return uri }
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }
}

public struct LinkInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var thumbnailURL: URL?
    public init(title: String, artist: String = "", thumbnailURL: URL? = nil) {
        self.title = title; self.artist = artist; self.thumbnailURL = thumbnailURL
    }
}

public protocol LinkInfoFetching: Sendable {
    func info(for kind: LinkKind) async throws -> LinkInfo
}

public enum LinkError: Error, Equatable, LocalizedError {
    case unsupported, badResponse, notAudio, tooLarge, insecure

    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "This link is not supported.")
        case .badResponse: String(localized: "The page did not answer as expected.")
        case .notAudio: String(localized: "That link is not a direct audio file.")
        case .tooLarge: String(localized: "That file is too large.")
        case .insecure: String(localized: "Only https links can be downloaded.")
        }
    }
}

/// Reads the public title of a Spotify or YouTube page through their oEmbed endpoints (no account, no key).
public final class OEmbedClient: LinkInfoFetching {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func info(for kind: LinkKind) async throws -> LinkInfo {
        let (endpoint, page): (String, URL)
        switch kind {
        case .spotify(let url): (endpoint, page) = ("https://open.spotify.com/oembed", url)
        case .youtube(let url): (endpoint, page) = ("https://www.youtube.com/oembed", url)
        default: throw LinkError.unsupported
        }
        var components = URLComponents(string: endpoint)!
        components.queryItems = [.init(name: "url", value: page.absoluteString), .init(name: "format", value: "json")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LinkError.badResponse }
        return try Self.parse(data, isYouTube: { if case .youtube = kind { true } else { false } }())
    }

    static func parse(_ data: Data, isYouTube: Bool) throws -> LinkInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTitle = json["title"] as? String, !rawTitle.isEmpty else { throw LinkError.badResponse }
        let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:))
        if isYouTube {
            var artist = (json["author_name"] as? String ?? "").replacingOccurrences(of: " - Topic", with: "")
            var title = FilenameCleaner.stripJunk(rawTitle)
            // "Artist - Title" in the video name is more reliable than the channel name
            if let r = title.range(of: " - ") {
                artist = String(title[title.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                title = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return LinkInfo(title: title, artist: artist, thumbnailURL: thumb)
        }
        return LinkInfo(title: rawTitle, artist: "", thumbnailURL: thumb)
    }
}

/// A song the person wants, remembered from a link, until the file arrives by a lawful route.
public struct WishItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var artist: String
    public var sourceURL: URL
    public var thumbnailURL: URL?
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, artist: String, sourceURL: URL, thumbnailURL: URL? = nil, addedAt: Date = .now) {
        self.id = id; self.title = title; self.artist = artist; self.sourceURL = sourceURL
        self.thumbnailURL = thumbnailURL; self.addedAt = addedAt
    }
}

/// The wishlist, kept in one small JSON file on this device.
public actor WishlistStore {
    private var items: [WishItem]
    private let url: URL?

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([WishItem].self, from: data) { items = saved }
        else { items = [] }
    }

    public func all() -> [WishItem] { items.sorted { $0.addedAt > $1.addedAt } }

    /// Adds the item unless the same link is already there. Returns false for a repeat.
    @discardableResult
    public func add(_ item: WishItem) -> Bool {
        guard !items.contains(where: { $0.sourceURL == item.sourceURL }) else { return false }
        items.append(item)
        save()
        return true
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Is this wish already in the library? Compares names loosely (case, accents and punctuation ignored).
public enum WishMatcher {
    public static func matches(_ wish: WishItem, title: String, artist: String) -> Bool {
        let wt = TagSanity.normalize(wish.title), lt = TagSanity.normalize(title)
        // "Song (4K Remaster)" on a video page still means the library's "Song"
        guard wt.count >= 3, lt.count >= 3, wt == lt || wt.hasPrefix(lt) || lt.hasPrefix(wt) else { return false }
        let wa = TagSanity.normalize(wish.artist)
        return wa.isEmpty || TagSanity.normalize(artist).isEmpty || wa == TagSanity.normalize(artist)
            || TagSanity.normalize(artist).contains(wa) || wa.contains(TagSanity.normalize(artist))
    }
}
