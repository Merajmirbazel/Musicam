import Foundation
import Domain
import Importing
import Metadata
import MerajCore

/// Gets a Spotify track, album or playlist entirely on this device: Spotify's public page gives the song details, the
/// app's embedded yt-dlp finds and downloads the audio, and the audio is finished into a tagged m4a with the cover.
/// No Mac, no server. Files go to `directory/<random folder>/<file name>` like every other provider.
public struct MerajfyLocalProvider: MediaProvider {
    public static let providerID = "merajfy-local"
    public let id = MerajfyLocalProvider.providerID
    public var displayName: String { String(localized: "Merajfy (on this iPhone)") }

    /// More than this in one playlist is cut off, so one request cannot run for hours.
    public static let maxSongsPerRequest = 100

    private let directory: URL
    private let session: URLSession
    private let gate: OnDeviceSwitch
    private let engine: @Sendable () -> (any YouTubeAudioEngine)?

    public init(directory: URL, gate: OnDeviceSwitch, session: URLSession = .shared,
                engine: @escaping @Sendable () -> (any YouTubeAudioEngine)? = { OnDeviceEngine.current }) {
        self.directory = directory
        self.gate = gate
        self.session = session
        self.engine = engine
    }

    public func canHandle(_ request: AcquisitionRequest) -> Bool {
        guard gate.isOn, engine() != nil, let url = request.url else { return false }
        if case .spotify(let link) = LinkParser.classify(url.absoluteString) { return MerajfyProvider.isSupportedSpotifyLink(link) }
        return false
    }

    private func fail(_ reason: String, retryable: Bool = false) -> AcquisitionError {
        .failed(provider: id, reason: reason, retryable: retryable)
    }

    public func acquire(_ request: AcquisitionRequest, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile] {
        guard let url = request.url else { throw AcquisitionError.invalidRequest(String(localized: "There is no link to download.")) }
        guard let engine = engine() else { throw fail(String(localized: "The downloader inside this app is not available.")) }
        let link: SpotifyLink
        do { link = try SpotifyURL.parse(url.absoluteString) } catch { throw fail(error.localizedDescription) }

        progress(AcquisitionProgress(message: String(localized: "Reading Spotify…")))
        let spotify = SpotifyClient(session: session)
        var tracks: [TrackInfo]
        do {
            switch link.kind {
            case .track: tracks = [try await spotify.track(id: link.id)]
            case .playlist, .album: tracks = try await spotify.tracks(id: link.id, kind: link.kind, skip: [])
            }
        } catch let error as MerajError {
            if case .cancelled = error { throw CancellationError() }
            throw fail(error.localizedDescription, retryable: { if case .network = error { true } else if case .rateLimited = error { true } else { false } }())
        }
        if tracks.isEmpty { throw fail(String(localized: "That link has no songs.")) }
        var truncated = false
        if tracks.count > Self.maxSongsPerRequest { tracks = Array(tracks.prefix(Self.maxSongsPerRequest)); truncated = true }

        let source = TrackSource.link(url: url).raw
        var files: [AcquiredFile] = []
        var failures: [String] = []
        do {
            for (index, track) in tracks.enumerated() {
                try Task.checkCancellation()
                let total = tracks.count
                let base = Double(index) / Double(total)
                let label = total == 1 ? String(localized: "Downloading…") : String(localized: "Downloading \(index + 1) of \(total)…")
                progress(AcquisitionProgress(fraction: base * 0.95, message: label))
                do {
                    let file = try await fetch(track, number: link.kind == .track ? nil : (track.position ?? index + 1), engine: engine, source: source) { fraction in
                        progress(AcquisitionProgress(fraction: (base + fraction / Double(total)) * 0.95, message: label))
                    }
                    files.append(file)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        } catch {
            files.forEach { $0.discard() }
            throw error
        }
        if files.isEmpty { throw fail(failures.first ?? String(localized: "Could not get that song.")) }
        if !failures.isEmpty || truncated {
            let text = truncated
                ? String(localized: "Only the first \(Self.maxSongsPerRequest) songs were taken.")
                : String(localized: "\(failures.count) song(s) could not be found.")
            progress(AcquisitionProgress(fraction: 1, message: text))
        }
        return files
    }

    /// One song: details from Spotify (done), YouTube search + match, download, finish with tags and cover.
    private func fetch(_ track: TrackInfo, number: Int?, engine: any YouTubeAudioEngine, source: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> AcquiredFile {
        var t = track
        // playlist pages carry no cover, album or year: take them from the song's own page
        if t.coverURL == nil || t.album == nil || t.releaseDate == nil, let e = try? await SpotifyClient(session: session).track(id: track.id) {
            t.coverURL = t.coverURL ?? e.coverURL
            t.album = t.album ?? e.album
            t.releaseDate = t.releaseDate ?? e.releaseDate
        }

        let candidates = try await rankedVideos(for: t, engine: engine)
        if candidates.isEmpty { throw fail(String(localized: "No confident YouTube match for “\(t.title)”.")) }

        // the best match first; when YouTube will not give its audio, the next best (up to three)
        var lastError: Error = fail(String(localized: "Could not get that song."))
        for videoID in candidates.prefix(3) {
            try Task.checkCancellation()
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let raw = try await engine.downloadAudio(videoID: videoID, into: folder) { progress(min($0, 0.9)) }
                progress(0.92)
                let options = DownloadOptions(format: .m4a, includeTrackNumber: false)
                let name = FileNaming.cap(FileNaming.compose(title: t.title, artists: t.artists, options: options, trackNumber: number))
                let output = folder.appendingPathComponent(name)
                let cover = await fetchCover(t.coverURL)
                try await M4ATagger.finish(raw: raw, output: output,
                                           tags: .init(title: t.title, artist: t.artists, album: t.album,
                                                       year: t.releaseDate.map { String($0.prefix(4)) }, cover: cover))
                try? FileManager.default.removeItem(at: raw)
                progress(1)
                return AcquiredFile(url: output, source: source, providerID: id, ownsFolder: true)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// Every plausible YouTube match, best first: the same choice Merajfy makes, repeated on what is left.
    private func rankedVideos(for track: TrackInfo, engine: any YouTubeAudioEngine) async throws -> [String] {
        let base = "ytsearch1:\(track.title) \(track.artists) audio"
        var queries = [YouTubeMatcher.widenSearch(base)]
        let fallback = YouTubeMatcher.simplifySearch(base)
        if !queries.contains(fallback) { queries.append(fallback) }
        var ranked: [String] = []
        for query in queries {
            try Task.checkCancellation()
            var pool = try await engine.search(query).filter { !ranked.contains($0.id) }
            while let id = YouTubeMatcher.select(candidates: pool, expectedTitle: track.title, expectedArtists: track.artists,
                                                 expectedDuration: track.durationMs.map { Double($0) / 1000 }, looseMatch: false) {
                ranked.append(id)
                pool.removeAll { $0.id == id }
                if ranked.count >= 3 { return ranked }
            }
            if !ranked.isEmpty { break }           // the first query already had matches; do not widen further
        }
        return ranked
    }

    private func fetchCover(_ urlString: String?) async -> Data? {
        guard let s = urlString, let url = URL(string: s) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "user-agent")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 100 else { return nil }
        return data
    }
}
