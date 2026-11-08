import Foundation
import Synchronization
import Domain
import Importing
import Metadata

/// Where the Merajfy helper runs. On the Mac it is usually `127.0.0.1:8787`; on the iPhone it is the Mac's address.
/// Merajfy is a separate program that finds the song and writes the audio file; Musicam only asks it and imports the result.
public struct MerajfyConfig: Sendable, Equatable {
    public var baseURL: URL
    public var token: String?
    /// "mp3", "m4a", "flac", ... (what Merajfy should produce)
    public var format: String
    public var quality: String

    public init(baseURL: URL, token: String? = nil, format: String = "mp3", quality: String = "192") {
        self.baseURL = baseURL
        self.token = (token?.isEmpty == false) ? token : nil
        self.format = format
        self.quality = quality
    }

    /// Accepts "192.168.1.5:8787", "mac.local", or a full http(s) URL. The port defaults to 8787.
    public static func parseAddress(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "http://" + t }
        guard var c = URLComponents(string: t), let host = c.host, !host.isEmpty else { return nil }
        if c.port == nil { c.port = 8787 }
        c.path = ""
        c.query = nil
        return c.url
    }
}

/// The current config, readable from any thread. The settings screen writes it; the provider reads it per request.
/// `nil` means the feature is off (or not set up yet).
public final class MerajfyConfigStore: Sendable {
    private let value: Mutex<MerajfyConfig?>
    private let prepareHook = Mutex<(@Sendable () async -> Void)?>(nil)
    public init(_ initial: MerajfyConfig? = nil) { value = Mutex(initial) }
    public var current: MerajfyConfig? { value.withLock { $0 } }
    public func set(_ config: MerajfyConfig?) { value.withLock { $0 = config } }
    /// Something to do right before each download, for example starting the built-in helper if it is not running.
    public func setPrepare(_ hook: (@Sendable () async -> Void)?) { prepareHook.withLock { $0 = hook } }
    func prepare() async { if let hook = prepareHook.withLock({ $0 }) { await hook() } }
}

/// What the Merajfy helper reports about a job. Only the fields Musicam needs.
struct MerajfyJob: Decodable, Sendable {
    struct Track: Decodable, Sendable {
        var id: String
        var title: String
        var state: String          // pending | downloading | done | failed | skipped
        var progress: Double
        var error: String?
    }
    var id: String
    var state: String              // queued | resolving | running | done | failed | cancelled
    var title: String
    var message: String
    var tracks: [Track]
}

/// A small HTTP client for the Merajfy helper (POST /v1/jobs, GET /v1/jobs/{id}, GET /v1/jobs/{id}/files/{track}).
public struct MerajfyClient: Sendable {
    public struct Health: Decodable, Sendable, Equatable {
        public let ok: String
        public let ytdlp: String
        public let ffmpeg: String
        public var toolsReady: Bool { ytdlp == "true" && ffmpeg == "true" }
    }

    let config: MerajfyConfig
    let session: URLSession

    public init(config: MerajfyConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        if let token = config.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    static func fail(_ reason: String, retryable: Bool) -> AcquisitionError {
        .failed(provider: MerajfyProvider.providerID, reason: reason, retryable: retryable)
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Self.fail(String(localized: "Musicam cannot reach Merajfy. Is it running on your Mac?"), retryable: true)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Self.fail(String(localized: "Merajfy sent an unreadable answer."), retryable: true)
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw Self.fail(String(localized: "Merajfy refused the token. Check it in Settings."), retryable: false)
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Self.fail(message ?? String(localized: "Merajfy answered with error \(http.statusCode)."), retryable: http.statusCode >= 500)
        }
    }

    public func health() async throws -> Health {
        let data = try await perform(request("v1/health", timeout: 6))
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else {
            throw Self.fail(String(localized: "That address does not look like Merajfy."), retryable: false)
        }
        return health
    }

    func createJob(url: URL) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString, "format": config.format, "quality": config.quality])
        let data = try await perform(request("v1/jobs", method: "POST", body: body))
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw Self.fail(String(localized: "Merajfy sent an unreadable answer."), retryable: true)
        }
        return id
    }

    func job(_ id: String) async throws -> MerajfyJob {
        let data = try await perform(request("v1/jobs/\(id)", timeout: 15))
        guard let job = try? JSONDecoder().decode(MerajfyJob.self, from: data) else {
            throw Self.fail(String(localized: "Merajfy sent an unreadable answer."), retryable: true)
        }
        return job
    }

    /// True when the helper accepts this config's token (a harmless read of the job list).
    public func jobsAreReadable() async throws -> Bool {
        _ = try await perform(request("v1/jobs", timeout: 6))
        return true
    }

    func cancel(_ id: String) async { _ = try? await perform(request("v1/jobs/\(id)", method: "DELETE", timeout: 10)) }

    /// Saves one finished track into `directory` and returns the file.
    func file(job: String, track: String, into directory: URL) async throws -> URL {
        let temp: URL, response: URLResponse
        do { (temp, response) = try await session.download(for: request("v1/jobs/\(job)/files/\(track)", timeout: 300)) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Self.fail(error.localizedDescription, retryable: true)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.fail(String(localized: "Merajfy could not hand over the file."), retryable: true)
        }
        let encoded = http.value(forHTTPHeaderField: "X-Meraj-Filename") ?? "\(track).audio"
        var name = (encoded.removingPercentEncoding ?? encoded).replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = "\(track).audio" }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}

/// Gets a Spotify track, album or playlist through the Merajfy helper: it finds the audio, tags it and hands over the files.
/// Musicam does not talk to any streaming service itself.
///
/// Files go to `directory/<random folder>/<file name>`, the same layout as the other providers, so they are removed the same way.
public struct MerajfyProvider: MediaProvider {
    public static let providerID = "merajfy"
    public let id = MerajfyProvider.providerID
    public var displayName: String { String(localized: "Merajfy") }

    private let directory: URL
    private let session: URLSession
    private let config: MerajfyConfigStore
    private let pollInterval: Duration

    public init(directory: URL, config: MerajfyConfigStore, session: URLSession = .shared, pollInterval: Duration = .seconds(1)) {
        self.directory = directory
        self.config = config
        self.session = session
        self.pollInterval = pollInterval
    }

    public func canHandle(_ request: AcquisitionRequest) -> Bool {
        guard config.current != nil, let url = request.url else { return false }
        if case .spotify(let link) = LinkParser.classify(url.absoluteString) { return Self.isSupportedSpotifyLink(link) }
        return false
    }

    /// Tracks, albums and playlists only (artist pages, podcasts and so on are not songs).
    static func isSupportedSpotifyLink(_ url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        guard let kind = parts.first else { return false }
        return ["track", "album", "playlist"].contains(kind)
    }

    public func acquire(_ request: AcquisitionRequest, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile] {
        guard let url = request.url else { throw AcquisitionError.invalidRequest(String(localized: "There is no link to download.")) }
        guard let current = config.current else {
            throw MerajfyClient.fail(String(localized: "Merajfy is not set up. Turn it on in Settings."), retryable: false)
        }
        progress(AcquisitionProgress(message: String(localized: "Asking Merajfy…")))
        await config.prepare()
        // the settings may have changed while the helper was starting
        let client = MerajfyClient(config: config.current ?? current, session: session)
        let jobID = try await client.createJob(url: url)
        let source = TrackSource.link(url: url).raw
        let directory = self.directory, providerID = self.id, pollInterval = self.pollInterval

        return try await withTaskCancellationHandler {
            var saved: [String: AcquiredFile] = [:]
            var order: [String] = []
            var last: MerajfyJob?
            do {
                while true {
                    try Task.checkCancellation()
                    let job = try await client.job(jobID)
                    last = job
                    let total = job.tracks.count
                    if total > 0 {
                        let fraction = job.tracks.reduce(0.0) { $0 + $1.progress } / Double(total)
                        let done = job.tracks.filter { $0.state == "done" || $0.state == "skipped" }.count
                        progress(AcquisitionProgress(fraction: fraction * 0.95, message: total == 1
                            ? String(localized: "Downloading…")
                            : String(localized: "Downloading \(done) of \(total)…")))
                    } else {
                        progress(AcquisitionProgress(message: job.message))
                    }
                    // take each finished track right away, while the next ones are still being made
                    for track in job.tracks where (track.state == "done" || track.state == "skipped") && saved[track.id] == nil {
                        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        let file = try await client.file(job: jobID, track: track.id, into: folder)
                        saved[track.id] = AcquiredFile(url: file, source: source, providerID: providerID, ownsFolder: true)
                        order.append(track.id)
                    }
                    if ["done", "failed", "cancelled"].contains(job.state) { break }
                    try await Task.sleep(for: pollInterval)
                }
            } catch {
                // whatever was already saved must not be left behind when the request fails or is cancelled
                saved.values.forEach { $0.discard() }
                throw error
            }
            let files = order.compactMap { saved[$0] }
            if files.isEmpty {
                let reason = last?.tracks.compactMap(\.error).first ?? last?.message ?? String(localized: "Merajfy could not get that song.")
                throw MerajfyClient.fail(reason, retryable: false)
            }
            if let failed = last?.tracks.filter({ $0.state == "failed" }).count, failed > 0 {
                progress(AcquisitionProgress(fraction: 1, message: String(localized: "\(failed) song(s) could not be found.")))
            }
            return files
        } onCancel: {
            Task { await client.cancel(jobID) }
        }
    }
}
