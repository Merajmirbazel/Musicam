import Testing
import Foundation
import Synchronization
@testable import Acquisition

/// A pretend Merajfy: answers /v1/health, /v1/jobs, /v1/jobs/{id}, /v1/jobs/{id}/files/{track} and records every request.
private final class FakeMerajfy: Sendable {
    struct Seen: Sendable { var method: String; var path: String; var auth: String?; var body: String }
    private static let all = Mutex<[String: FakeMerajfy]>([:])
    private let id = UUID().uuidString
    private let log = Mutex<[Seen]>([])
    /// Set by the test: the job snapshots to return, one per poll (the last repeats).
    let snapshots = Mutex<[String]>([])
    let polls = Mutex<Int>(0)
    let createStatus = Mutex<Int>(201)
    let fileHeaders = Mutex<[String: [String: String]]>([:])   // track id -> headers

    init() { Self.all.withLock { $0[id] = self } }

    var requests: [Seen] { log.withLock { $0 } }
    var cancelled: Bool { requests.contains { $0.method == "DELETE" } }

    static func find(_ request: URLRequest) -> FakeMerajfy? {
        guard let id = request.value(forHTTPHeaderField: "X-Fake") else { return nil }
        return all.withLock { $0[id] }
    }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeMerajfyProtocol.self]
        config.httpAdditionalHeaders = ["X-Fake": id]
        return URLSession(configuration: config)
    }

    func answer(_ request: URLRequest, body: Data) -> (Int, [String: String], Data) {
        let path = request.url?.path ?? ""
        log.withLock { $0.append(Seen(method: request.httpMethod ?? "GET", path: path, auth: request.value(forHTTPHeaderField: "Authorization"),
                                      body: String(decoding: body, as: UTF8.self))) }
        let json = ["Content-Type": "application/json"]
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/v1/health"): return (200, json, Data(#"{"ok":"true","ytdlp":"true","ffmpeg":"true","name":"Merajfy"}"#.utf8))
        case ("POST", "/v1/jobs"):
            let status = createStatus.withLock { $0 }
            return status == 201 ? (201, json, Data(#"{"id":"j1"}"#.utf8)) : (status, json, Data(#"{"error":"nope"}"#.utf8))
        case ("DELETE", _): return (204, json, Data())
        case ("GET", "/v1/jobs/j1"):
            let n = polls.withLock { let v = $0; $0 += 1; return v }
            let list = snapshots.withLock { $0 }
            return (200, json, Data(list[min(n, list.count - 1)].utf8))
        default:
            if path.hasPrefix("/v1/jobs/j1/files/") {
                let track = String(path.dropFirst("/v1/jobs/j1/files/".count))
                var headers = ["Content-Type": "audio/mpeg"]
                headers.merge(fileHeaders.withLock { $0[track] } ?? [:]) { $1 }
                return (200, headers, Data("audio-\(track)".utf8))
            }
            return (404, json, Data(#"{"error":"not found"}"#.utf8))
        }
    }
}

private final class FakeMerajfyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = FakeMerajfy.find(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let (status, headers, data) = server.answer(request, body: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func snapshot(state: String, tracks: [(id: String, state: String, progress: Double, error: String?)], message: String = "") -> String {
    let rows = tracks.map { t in
        #"{"id":"\#(t.id)","title":"T\#(t.id)","artists":"A","state":"\#(t.state)","progress":\#(t.progress)\#(t.error.map { #","error":"\#($0)""# } ?? "")}"#
    }.joined(separator: ",")
    return #"{"id":"j1","url":"u","state":"\#(state)","title":"List","message":"\#(message)","tracks":[\#(rows)]}"#
}

private let spotifyTrack = URL(string: "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8")!

private func provider(_ dir: URL, _ fake: FakeMerajfy, config: MerajfyConfig? = MerajfyConfig(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "secret", format: "m4a")) -> MerajfyProvider {
    MerajfyProvider(directory: dir, config: MerajfyConfigStore(config), session: fake.session, pollInterval: .milliseconds(10))
}

@Suite struct MerajfyProviderTests {
    @Test func handlesOnlySpotifySongLinksAndOnlyWhenSetUp() {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeMerajfy()
        let on = provider(dir, fake)
        #expect(on.canHandle(.link(spotifyTrack)))
        #expect(on.canHandle(.link(URL(string: "https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3?si=x")!)))
        #expect(on.canHandle(.link(URL(string: "https://open.spotify.com/intl-de/playlist/37i9dQZF1DXcBWIGoYBM5M")!)))
        #expect(!on.canHandle(.link(URL(string: "https://open.spotify.com/artist/1")!)))
        #expect(!on.canHandle(.link(URL(string: "https://www.youtube.com/watch?v=abc")!)))
        #expect(!on.canHandle(.link(URL(string: "https://example.org/a.mp3")!)))
        #expect(!on.canHandle(AcquisitionRequest(query: "song")))
        #expect(!provider(dir, fake, config: nil).canHandle(.link(spotifyTrack)))
    }

    @Test func downloadsATrackAndSendsTheSettings() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeMerajfy()
        fake.snapshots.withLock { $0 = [
            snapshot(state: "running", tracks: [("a", "downloading", 0.4, nil)]),
            snapshot(state: "done", tracks: [("a", "done", 1, nil)]),
        ] }
        fake.fileHeaders.withLock { $0["a"] = ["X-Meraj-Filename": "Never%20Gonna%20Give%20You%20Up%20-%20Rick%20Astley.mp3"] }
        let fractions = Mutex<[Double]>([])
        let files = try await provider(dir, fake).acquire(.link(spotifyTrack)) { p in if let f = p.fraction { fractions.withLock { $0.append(f) } } }

        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.url.lastPathComponent == "Never Gonna Give You Up - Rick Astley.mp3")
        #expect(file.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(file.source == "link:open.spotify.com")
        #expect(file.providerID == "merajfy" && file.ownsFolder && file.problem == nil)
        #expect(!fractions.withLock { $0 }.isEmpty)

        let create = try #require(fake.requests.first { $0.method == "POST" })
        #expect(create.auth == "Bearer secret")
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(create.body.utf8)) as? [String: String])
        #expect(sent["url"] == spotifyTrack.absoluteString && sent["format"] == "m4a" && sent["quality"] == "192")
    }

    @Test func anAlbumReturnsEveryFinishedSongEvenIfOneIsMissing() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeMerajfy()
        fake.snapshots.withLock { $0 = [snapshot(state: "done", tracks: [("a", "done", 1, nil), ("b", "failed", 0, "No confident YouTube match"), ("c", "skipped", 1, nil)])] }
        for t in ["a", "c"] { fake.fileHeaders.withLock { $0[t] = ["X-Meraj-Filename": "\(t).mp3"] } }
        let message = Mutex<String?>(nil)
        let files = try await provider(dir, fake).acquire(.link(URL(string: "https://open.spotify.com/album/x")!)) { p in
            if let m = p.message { message.withLock { $0 = m } }
        }
        #expect(files.map { $0.url.lastPathComponent } == ["a.mp3", "c.mp3"])
        #expect(message.withLock { $0 } != nil)
    }

    @Test func aJobWithNoFilesFailsWithMerajfysReason() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeMerajfy()
        fake.snapshots.withLock { $0 = [snapshot(state: "done", tracks: [("a", "failed", 0, "No confident YouTube match")])] }
        do { _ = try await provider(dir, fake).acquire(.link(spotifyTrack)) { _ in }; Issue.record("expected a failure") }
        catch let e as AcquisitionError {
            guard case .failed("merajfy", let reason, false) = e else { Issue.record("wrong error \(e)"); return }
            #expect(reason.contains("No confident YouTube match"))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }

    @Test func connectionAndTokenProblemsAreExplained() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeMerajfy()
        fake.createStatus.withLock { $0 = 401 }
        do { _ = try await provider(dir, fake).acquire(.link(spotifyTrack)) { _ in }; Issue.record("expected a failure") }
        catch let e as AcquisitionError { #expect(!e.isRetryable) }

        // no server at all: the session fails every request
        let nowhere = MerajfyProvider(directory: dir, config: MerajfyConfigStore(MerajfyConfig(baseURL: URL(string: "http://127.0.0.1:1")!)),
                                      session: URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FakeMerajfyProtocol.self]; return c }()))
        do { _ = try await nowhere.acquire(.link(spotifyTrack)) { _ in }; Issue.record("expected a failure") }
        catch let e as AcquisitionError { #expect(e.isRetryable) }
    }

    @Test func cancellingTellsMerajfyAndLeavesNothingBehind() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeMerajfy()
        fake.snapshots.withLock { $0 = [snapshot(state: "running", tracks: [("a", "done", 1, nil), ("b", "downloading", 0.2, nil)])] }
        fake.fileHeaders.withLock { $0["a"] = ["X-Meraj-Filename": "a.mp3"] }
        let p = provider(dir, fake)
        let task = Task { try await p.acquire(.link(spotifyTrack)) { _ in } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") } catch is CancellationError {} catch { Issue.record("wrong error \(error)") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.cancelled)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.allSatisfy { name in
            (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(name).path))?.isEmpty ?? true } ?? true)
    }

    @Test func theManagerImportsWhatMerajfyDelivers() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeMerajfy()
        fake.snapshots.withLock { $0 = [snapshot(state: "done", tracks: [("a", "done", 1, nil)])] }
        fake.fileHeaders.withLock { $0["a"] = ["X-Meraj-Filename": "Song.mp3"] }
        let recorder = HandoffRecorder()
        let registry = try ProviderRegistry([provider(dir, fake)])
        let job = await MainActor.run { AcquisitionManager(registry: registry, handoff: recorder.handoff) }
        let done = await job.perform(.link(spotifyTrack))
        #expect(done.state == .finished(files: 1))
        #expect(recorder.files.map { $0.source } == ["link:open.spotify.com"])
        #expect(await job.canHandle(.link(spotifyTrack)))
    }

    @Test func addressesAreParsedForTheSettingsField() {
        #expect(MerajfyConfig.parseAddress("192.168.1.20")?.absoluteString == "http://192.168.1.20:8787")
        #expect(MerajfyConfig.parseAddress(" mac.local:9000 ")?.absoluteString == "http://mac.local:9000")
        #expect(MerajfyConfig.parseAddress("https://x.example.org")?.absoluteString == "https://x.example.org:8787")
        #expect(MerajfyConfig.parseAddress("") == nil)
    }
}
