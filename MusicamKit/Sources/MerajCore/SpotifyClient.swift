import Foundation

/// Parses the `__NEXT_DATA__` JSON that Spotify's embed pages carry.
/// Kept separate from networking so it can be tested offline with fixtures.
public enum EmbedParser {
    public typealias JSON = [String: Any]

    static let entityPaths: [[String]] = [
        ["props", "pageProps", "state", "data", "entity"],
        ["props", "pageProps", "data", "entity"],
        ["props", "pageProps", "entity"],
    ]
    static let tokenPaths: [[String]] = [
        ["props", "pageProps", "state", "settings", "session"],
        ["props", "pageProps", "settings", "session"],
        ["props", "pageProps", "session"],
    ]

    public static func nextData(fromHTML html: String) throws -> JSON {
        let re = try! NSRegularExpression(pattern: #"<script id="__NEXT_DATA__"[^>]*>([^<]+)</script>"#)
        guard let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html)
        else { throw MerajError.extraction("Could not find __NEXT_DATA__ in embed page") }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(html[r].utf8)) as? JSON else {
            throw MerajError.extraction("Invalid JSON in __NEXT_DATA__")
        }
        return obj
    }

    static func resolve(_ data: JSON, _ path: [String]) -> Any? {
        var cur: Any? = data
        for k in path {
            guard let d = cur as? JSON else { return nil }
            cur = d[k]
        }
        return cur
    }

    static func deepFind(_ data: JSON, key: String, maxDepth: Int = 6) -> JSON? {
        if maxDepth <= 0 { return nil }
        if data[key] != nil { return data }
        for v in data.values {
            if let d = v as? JSON, let r = deepFind(d, key: key, maxDepth: maxDepth - 1) { return r }
        }
        return nil
    }

    public static func token(from data: JSON) -> (token: String, expiry: Date)? {
        for p in tokenPaths {
            if let s = resolve(data, p) as? JSON, let t = s["accessToken"] as? String {
                let ms = (s["accessTokenExpirationTimestampMs"] as? NSNumber)?.doubleValue ?? 0
                return (t, ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : .distantPast)
            }
        }
        return nil
    }

    public static func entity(from data: JSON) throws -> JSON {
        for p in entityPaths { if let e = resolve(data, p) as? JSON { return e } }
        if let c = deepFind(data, key: "trackList"), c["trackList"] != nil { return c }
        if let c = deepFind(data, key: "type"), let t = c["type"] as? String, t == "playlist" || t == "track" { return c }
        let pageProps = resolve(data, ["props", "pageProps"]) as? JSON ?? [:]
        if pageProps["status"] != nil && pageProps["state"] == nil {
            throw MerajError.unavailable(
                "Spotify returned an unavailable page for this link. That happens when the item is private, "
                + "removed, or region-locked - and for every link if Spotify does not operate in your country.")
        }
        throw MerajError.extraction("Could not find entity in embed page. pageProps keys: \(Array(pageProps.keys.prefix(10)))")
    }

    static func joinArtists(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let arr = v as? [Any] {
            return arr.compactMap { ($0 as? JSON)?["name"] as? String }.joined(separator: ", ")
        }
        return ""
    }

    static func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { let i = n.intValue; return i == 0 ? nil : i }
        return nil
    }

    public static func playlistInfo(from entity: JSON) -> PlaylistInfo {
        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Unknown Playlist"
        let subtitle = entity["subtitle"] as? String
        var cover: String?
        if let art = entity["coverArt"] as? JSON, let src = art["sources"] as? [JSON], let last = src.last {
            cover = last["url"] as? String
        }
        if cover == nil, let vi = entity["visualIdentity"] as? JSON, let imgs = vi["image"] as? [JSON], let last = imgs.last {
            cover = last["url"] as? String
        }
        let count = (entity["trackList"] as? [Any])?.count ?? 0
        return PlaylistInfo(name: name, owner: (subtitle?.isEmpty == false) ? subtitle : nil,
                            description: entity["description"] as? String, coverURL: cover, trackCount: count)
    }

    /// Track from an embed playlist/album `trackList` row.
    public static func trackFromList(_ t: JSON, id: String) -> TrackInfo {
        let title = (t["title"] as? String) ?? (t["name"] as? String) ?? "Unknown Track"
        let artists = joinArtists(t["subtitle"] ?? t["artists"])
        var preview: String?
        if let ap = t["audioPreview"] as? JSON { preview = ap["url"] as? String }
        var album: String?
        if let a = t["album"] as? JSON { album = a["name"] as? String }
        return TrackInfo(id: id, title: title, artists: artists, album: album,
                         releaseDate: t["releaseDate"] as? String, coverURL: nil,
                         durationMs: intValue(t["duration"]), previewURL: preview)
    }

    /// Track from a single-track embed page entity (album filled in by caller).
    public static func trackFromEntity(_ e: JSON, id: String, album: String?) -> TrackInfo {
        let title = (e["name"] as? String) ?? (e["title"] as? String) ?? "Unknown Track"
        let artists: String
        if let list = e["artists"] as? [Any] { artists = joinArtists(list) } else { artists = (e["subtitle"] as? String) ?? "" }
        var preview: String?
        if let ap = e["audioPreview"] as? JSON { preview = ap["url"] as? String }
        var cover: String?
        if let vi = e["visualIdentity"] as? JSON, let imgs = vi["image"] as? [JSON] {
            for img in imgs {
                if let u = img["url"] as? String, !u.isEmpty {
                    cover = u
                    if ((img["maxWidth"] as? NSNumber)?.intValue ?? 0) >= 300 { break }
                }
            }
        }
        var release: String?
        if let rd = e["releaseDate"] as? JSON { release = (rd["isoString"] as? String).map { String($0.prefix(10)) } }
        else if let rd = e["releaseDate"] as? String { release = rd }
        return TrackInfo(id: id, title: title, artists: artists, album: album, releaseDate: release,
                         coverURL: cover, durationMs: intValue(e["duration"]), previewURL: preview)
    }

    /// Album name from the social-crawler track page's og:description ("Artist · Album · Song · Year").
    public static func albumFromOGDescription(html: String) -> String? {
        let re = try! NSRegularExpression(
            pattern: #"<meta\s+(?=[^>]*\bproperty="og:description")[^>]*\bcontent="([^"]*)""#,
            options: .caseInsensitive)
        guard let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        let decoded = decodeEntities(String(html[r]))
        let parts = decoded.components(separatedBy: " · ")
        guard parts.count >= 2 else { return nil }
        let album = parts[1].trimmingCharacters(in: .whitespaces)
        return album.isEmpty ? nil : album
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

/// Anonymous Spotify access via embed pages. No login, no API key.
public actor SpotifyClient {
    private let session: URLSession
    private var token: String?
    private var tokenExpiry: Date = .distantPast
    private var albumCache: [String: String] = [:]

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let crawlerUA = "facebookexternalhit/1.1"

    public init(session: URLSession = .shared) { self.session = session }

    // MARK: networking

    private func retry<T>(attempts: Int, backoff: Double, _ op: () async throws -> T) async throws -> T {
        var last: Error = MerajError.network("unknown")
        for i in 0..<attempts {
            do { return try await op() } catch let e as MerajError {
                switch e {
                case .network, .rateLimited:
                    last = e
                    if i < attempts - 1 { try await Task.sleep(for: .seconds(backoff * pow(2, Double(i)))) }
                default: throw e
                }
            }
        }
        throw last
    }

    private func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw MerajError.network("not an HTTP response") }
            return (data, http)
        } catch let e as MerajError { throw e }
        catch is CancellationError { throw MerajError.cancelled }
        catch { throw MerajError.network(error.localizedDescription) }
    }

    private func pageHeaders() -> [String: String] {
        ["accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
         "accept-language": "en-US,en;q=0.9", "user-agent": Self.userAgent]
    }

    private func fetchEmbedData(_ url: URL) async throws -> EmbedParser.JSON {
        try await retry(attempts: 4, backoff: 1.5) {
            let (data, resp) = try await get(url, headers: pageHeaders(), timeout: 30)
            switch resp.statusCode {
            case 429: throw MerajError.rateLimited
            case 401, 403: throw MerajError.extraction("Access denied (HTTP \(resp.statusCode)) - playlist may be private")
            case 200: break
            default: throw MerajError.network("Embed page returned HTTP \(resp.statusCode)")
            }
            let html = String(decoding: data, as: UTF8.self)
            let json = try EmbedParser.nextData(fromHTML: html)
            if let t = EmbedParser.token(from: json) { token = t.token; tokenExpiry = t.expiry }
            return json
        }
    }

    private func embedURL(_ id: String, _ kind: SpotifyKind) -> URL {
        URL(string: "https://open.spotify.com/embed/\(kind.rawValue)/\(id)")!
    }

    // MARK: public API

    public func playlistInfo(id: String, kind: SpotifyKind = .playlist) async throws -> PlaylistInfo {
        let data = try await fetchEmbedData(embedURL(id, kind))
        let entity = try EmbedParser.entity(from: data)
        var info = EmbedParser.playlistInfo(from: entity)
        if kind == .playlist, let t = token, let n = await spclientLength(id: id, token: t) { info.trackCount = n }
        return info
    }

    public func track(id: String) async throws -> TrackInfo {
        guard let t = try await fetchTrack(id: id) else { throw MerajError.extraction("Could not fetch track \(id)") }
        return t
    }

    /// All tracks of a playlist/album. Embed pages hold ~100; larger playlists are completed via spclient.
    public func tracks(id: String, kind: SpotifyKind, skip: Set<String> = []) async throws -> [TrackInfo] {
        let data = try await fetchEmbedData(embedURL(id, kind))
        let entity = try EmbedParser.entity(from: data)
        let albumName = kind == .album ? entity["name"] as? String : nil
        var out: [TrackInfo] = []
        var embedIDs: Set<String> = []
        for (i, row) in ((entity["trackList"] as? [Any]) ?? []).enumerated() {
            guard let t = row as? EmbedParser.JSON, let uri = t["uri"] as? String,
                  uri.hasPrefix("spotify:track:"), let tid = uri.split(separator: ":").last.map(String.init)
            else { continue }
            embedIDs.insert(tid)
            if skip.contains(tid) { continue }
            var info = EmbedParser.trackFromList(t, id: tid)
            info.position = i + 1
            if info.album == nil, let a = albumName { info.album = a }
            out.append(info)
        }
        guard kind == .playlist, let tok = token else { return out }
        guard let spc = await spclientPlaylist(id: id, token: tok) else { return out }
        let total = (spc["length"] as? NSNumber)?.intValue ?? 0
        if total <= embedIDs.count { return out }
        let items = ((spc["contents"] as? EmbedParser.JSON)?["items"] as? [EmbedParser.JSON]) ?? []
        var positions: [String: Int] = [:]
        var pending: [String] = []
        for (i, item) in items.enumerated() {
            guard let uri = item["uri"] as? String, uri.hasPrefix("spotify:track:"),
                  let tid = uri.split(separator: ":").last.map(String.init) else { continue }
            positions[tid] = i + 1
            if embedIDs.contains(tid) || skip.contains(tid) { continue }
            pending.append(tid)
        }
        // metadata for the rest, 4 at a time
        var idx = 0
        while idx < pending.count {
            let batch = Array(pending[idx..<min(idx + 4, pending.count)])
            idx += 4
            let results: [(String, TrackInfo?)] = await withTaskGroup(of: (String, TrackInfo?).self) { group in
                for tid in batch { group.addTask { (tid, try? await self.fetchTrack(id: tid)) } }
                var r: [(String, TrackInfo?)] = []
                for await x in group { r.append(x) }
                return r
            }
            for (tid, info) in results {
                var t = info ?? TrackInfo(id: tid, title: "Track \(tid)", artists: "Unknown Artist")
                t.position = positions[tid]
                out.append(t)
            }
        }
        return out.sorted { ($0.position ?? .max) < ($1.position ?? .max) }
    }

    // MARK: internals

    func fetchTrack(id: String) async throws -> TrackInfo? {
        let data: EmbedParser.JSON
        let entity: EmbedParser.JSON
        do {
            data = try await fetchEmbedData(embedURL(id, .track))
            entity = try EmbedParser.entity(from: data)
        } catch MerajError.unavailable(let m) { throw MerajError.unavailable(m) }
        catch is MerajError { return nil }
        let album = await albumFromTrackPage(id: id)
        return EmbedParser.trackFromEntity(entity, id: id, album: album)
    }

    private func albumFromTrackPage(id: String) async -> String? {
        if let c = albumCache[id] { return c }
        var h = pageHeaders()
        h["user-agent"] = Self.crawlerUA
        guard let url = URL(string: "https://open.spotify.com/track/\(id)") else { return nil }
        let result: String? = try? await retry(attempts: 3, backoff: 1.0) {
            let (data, resp) = try await get(url, headers: h, timeout: 15)
            guard resp.statusCode == 200 else { return nil }
            return EmbedParser.albumFromOGDescription(html: String(decoding: data, as: UTF8.self))
        }
        if let a = result {
            if albumCache.count >= 256, let first = albumCache.keys.first { albumCache.removeValue(forKey: first) }
            albumCache[id] = a
        }
        return result
    }

    private func spclientPlaylist(id: String, token: String) async -> EmbedParser.JSON? {
        guard let url = URL(string: "https://spclient.wg.spotify.com/playlist/v2/playlist/\(id)") else { return nil }
        guard let (data, resp) = try? await get(url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"], timeout: 30),
              resp.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? EmbedParser.JSON
    }

    private func spclientLength(id: String, token: String) async -> Int? {
        guard let spc = await spclientPlaylist(id: id, token: token) else { return nil }
        return (spc["length"] as? NSNumber)?.intValue
    }
}
