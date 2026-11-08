import Testing
import Foundation
import AVFoundation
import MerajCore
@testable import Acquisition

/// An engine that pretends to be Python + yt-dlp: it "finds" videos and "downloads" a real AAC file.
private final class FakeEngine: YouTubeAudioEngine, @unchecked Sendable {
    var results: [YTCandidate]
    var downloadError: Error?
    /// video ids that fail with this error while the others work
    var failingVideos: Set<String> = []
    var delay: Duration = .zero
    private(set) var downloaded: [String] = []
    init(results: [YTCandidate]) { self.results = results }

    func search(_ query: String) async throws -> [YTCandidate] { results }

    func downloadAudio(videoID: String, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        downloaded.append(videoID)
        progress(0.5)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let downloadError { throw downloadError }
        if failingVideos.contains(videoID) { throw NSError(domain: "x", code: 2, userInfo: [NSLocalizedDescriptionKey: "The matched YouTube video is unavailable."]) }
        let url = directory.appendingPathComponent("raw-\(videoID).m4a")
        try makeAAC(at: url, seconds: 2)
        return url
    }
}

/// A short real AAC file, standing in for what yt-dlp saves.
private func makeAAC(at url: URL, seconds: Double) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let frames = AVAudioFrameCount(44100 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
    try file.write(from: buffer)
}

private func embedHTML(_ name: String) -> Data {
    let json = """
    {"props":{"pageProps":{"state":{"data":{"entity":{"name":"\(name)","artists":[{"name":"Rick Astley"}],"duration":2000,"releaseDate":{"isoString":"1987-07-27T00:00:00Z"},"visualIdentity":{"image":[{"url":"https://img.example/cover.jpg","maxWidth":640}]}}}}}}}
    """
    return Data("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>".utf8)
}

@Suite struct MerajfyLocalProviderTests {
    private func provider(_ engine: FakeEngine, gate: Bool = true, folder: URL) -> (MerajfyLocalProvider, StubServer) {
        let server = StubServer { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/embed/track/") { return (200, "text/html", embedHTML("Never Gonna Give You Up")) }
            if url.hasSuffix("cover.jpg") { return (200, "image/jpeg", Data(repeating: 0xFF, count: 400)) }
            return (404, "text/plain", Data())
        }
        let p = MerajfyLocalProvider(directory: folder, gate: OnDeviceSwitch(gate), session: server.session, engine: { engine })
        return (p, server)
    }

    private let link = URL(string: "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8")!

    @Test func acceptsSpotifyLinksOnlyWhileSwitchedOnAndWithAnEngine() {
        let engine = FakeEngine(results: [])
        let folder = makeScratchFolder()
        #expect(provider(engine, gate: true, folder: folder).0.canHandle(.link(link)))
        #expect(!provider(engine, gate: false, folder: folder).0.canHandle(.link(link)))
        #expect(!provider(engine, gate: true, folder: folder).0.canHandle(.link(URL(string: "https://open.spotify.com/artist/abc")!)))
        #expect(!provider(engine, gate: true, folder: folder).0.canHandle(.link(URL(string: "https://example.org/a.mp3")!)))
        let none = MerajfyLocalProvider(directory: folder, gate: OnDeviceSwitch(true), engine: { nil })
        #expect(!none.canHandle(.link(link)))
    }

    @Test func aSongBecomesATaggedM4AWithItsCoverAndNothingElseIsLeftBehind() async throws {
        let engine = FakeEngine(results: [YTCandidate(id: "vid1", title: "Rick Astley - Never Gonna Give You Up (Official Audio)", duration: 2)])
        let folder = makeScratchFolder()
        let (p, _) = provider(engine, folder: folder)
        let files = try await p.acquire(.link(link)) { _ in }

        let file = try #require(files.first)
        #expect(files.count == 1 && engine.downloaded == ["vid1"])
        #expect(file.url.lastPathComponent == "Never Gonna Give You Up - Rick Astley.m4a")
        #expect(file.source == "link:open.spotify.com" && file.ownsFolder)
        #expect(file.url.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())   // the one-level layout the sweeper expects
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path) == [file.url.lastPathComponent])

        let asset = AVURLAsset(url: file.url)
        let titles = try await asset.load(.commonMetadata)
        func value(_ key: AVMetadataKey) async throws -> String? {
            guard let item = AVMetadataItem.metadataItems(from: titles, filteredByIdentifier: AVMetadataItem.identifier(forKey: key, keySpace: .common)!).first else { return nil }
            return try await item.load(.stringValue)
        }
        #expect(try await value(.commonKeyTitle) == "Never Gonna Give You Up")
        #expect(try await value(.commonKeyArtist) == "Rick Astley")
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.3)
        #expect(AVMetadataItem.metadataItems(from: titles, filteredByIdentifier: .commonIdentifierArtwork).count == 1)
    }

    @Test func noConfidentMatchFailsAndDownloadsNothing() async throws {
        let engine = FakeEngine(results: [YTCandidate(id: "x", title: "Completely different song", duration: 200)])
        let folder = makeScratchFolder()
        let (p, _) = provider(engine, folder: folder)
        await #expect(throws: AcquisitionError.self) { try await p.acquire(.link(link)) { _ in } }
        #expect(engine.downloaded.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aFailedDownloadLeavesNoFolderBehind() async throws {
        let engine = FakeEngine(results: [YTCandidate(id: "vid1", title: "Rick Astley - Never Gonna Give You Up", duration: 2)])
        engine.downloadError = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "No internet connection."])
        let folder = makeScratchFolder()
        let (p, _) = provider(engine, folder: folder)
        do { _ = try await p.acquire(.link(link)) { _ in }; Issue.record("should have failed") }
        catch { #expect(error.localizedDescription.contains("No internet connection")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func cancellingStopsTheRequestAndRemovesItsFiles() async throws {
        let engine = FakeEngine(results: [YTCandidate(id: "vid1", title: "Rick Astley - Never Gonna Give You Up", duration: 2)])
        engine.delay = .seconds(5)
        let folder = makeScratchFolder()
        let (p, _) = provider(engine, folder: folder)
        let link = self.link
        let task = Task { try await p.acquire(.link(link)) { _ in } }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func whenTheBestMatchCannotBeDownloadedTheNextBestIsTried() async throws {
        let engine = FakeEngine(results: [YTCandidate(id: "blocked", title: "Rick Astley - Never Gonna Give You Up (Official Video)", duration: 2),
                                          YTCandidate(id: "works", title: "Rick Astley - Never Gonna Give You Up", duration: 3)])
        engine.failingVideos = ["blocked"]
        let folder = makeScratchFolder()
        let (p, _) = provider(engine, folder: folder)
        let files = try await p.acquire(.link(link)) { _ in }
        #expect(files.count == 1)
        #expect(engine.downloaded == ["blocked", "works"])
        // the failed attempt left no folder behind
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }
}
