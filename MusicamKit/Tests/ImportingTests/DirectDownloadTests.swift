import Testing
import Foundation
@testable import Importing

/// Serves canned responses so the downloader can be tested without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (response, data) = Self.handler?(request) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct DirectDownloadTests {
    private func downloader() -> (DirectAudioDownloader, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID())")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return (DirectAudioDownloader(directory: dir, session: URLSession(configuration: config)), dir)
    }

    private func respond(_ url: URL, type: String, status: Int = 200, body: Data = Data("abc".utf8)) {
        StubProtocol.handler = { _ in
            (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!, body)
        }
    }

    @Test func savesAnAudioFileUnderItsOwnName() async throws {
        let (d, dir) = downloader(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.org/files/My%20Song.mp3")!
        respond(url, type: "audio/mpeg")
        let saved = try await d.download(url)
        #expect(saved.lastPathComponent == "My Song.mp3")
        #expect(try Data(contentsOf: saved) == Data("abc".utf8))
    }

    @Test func refusesWebPagesPlainHTTPAndErrors() async throws {
        let (d, dir) = downloader(); defer { try? FileManager.default.removeItem(at: dir) }
        let page = URL(string: "https://example.org/song.mp3")!
        respond(page, type: "text/html")
        await #expect(throws: DirectDownloadError.notAudio) { _ = try await d.download(page) }
        await #expect(throws: DirectDownloadError.notHTTPS) { _ = try await d.download(URL(string: "http://example.org/a.mp3")!) }
        respond(page, type: "audio/mpeg", status: 404)
        await #expect(throws: DirectDownloadError.failed(404)) { _ = try await d.download(page) }
        respond(page, type: "application/octet-stream")                         // generic type is fine when the name says audio
        _ = try await d.download(page)
    }
}
