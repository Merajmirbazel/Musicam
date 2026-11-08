import Foundation
import Synchronization
@testable import Acquisition

func makeScratchFolder() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acq-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A file in a folder of its own, as a provider would deliver it.
func makeAcquiredFile(in root: URL, name: String = "song.mp3", bytes: Data = Data("abc".utf8), source: String = "link:example.org") -> AcquiredFile {
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try? bytes.write(to: url)
    return AcquiredFile(url: url, source: source, providerID: "fake", ownsFolder: true)
}

/// A provider whose behaviour the test writes.
struct FakeProvider: MediaProvider {
    let id: String
    var displayName: String { id }
    var accepts: @Sendable (AcquisitionRequest) -> Bool
    var work: @Sendable (AcquisitionRequest, @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile]

    typealias Work = @Sendable (AcquisitionRequest, @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile]

    init(id: String, work: @escaping Work) {
        self.id = id; self.accepts = { _ in true }; self.work = work
    }

    init(id: String, accepts: @escaping @Sendable (AcquisitionRequest) -> Bool = { _ in true }) {
        self.id = id; self.accepts = accepts; self.work = { _, _ in [] }
    }

    func canHandle(_ request: AcquisitionRequest) -> Bool { accepts(request) }
    func acquire(_ request: AcquisitionRequest, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile] {
        try await work(request, progress)
    }
}

/// Collects what the manager handed to the importer.
final class HandoffRecorder: Sendable {
    private let batches = Mutex<[[AcquiredFile]]>([])
    var all: [[AcquiredFile]] { batches.withLock { $0 } }
    var files: [AcquiredFile] { all.flatMap { $0 } }
    var handoff: AcquisitionHandoff { { [self] files in batches.withLock { $0.append(files) } } }
}

/// A pretend web server: each test makes its own, so tests can run side by side.
final class StubServer: Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String, Data)
    private static let servers = Mutex<[String: StubServer]>([:])
    private let id = UUID().uuidString
    private let handler = Mutex<Handler>({ _ in (404, "text/plain", Data()) })

    init(_ handler: @escaping Handler = { _ in (200, "audio/mpeg", Data("abc".utf8)) }) {
        self.handler.withLock { $0 = handler }
        Self.servers.withLock { $0[id] = self }
    }

    func respond(_ handler: @escaping Handler) { self.handler.withLock { $0 = handler } }
    func answer(_ request: URLRequest) -> (Int, String, Data) { handler.withLock { $0 }(request) }
    static func server(for request: URLRequest) -> StubServer? {
        guard let id = request.value(forHTTPHeaderField: "X-Stub") else { return nil }
        return servers.withLock { $0[id] }
    }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub": id]
        return URLSession(configuration: config)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = StubServer.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, type, data) = server.answer(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Waits (politely) until something becomes true.
@MainActor
func waitUntil(timeout: Double = 5, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
}

/// A small valid WAV so the real importer accepts it.
func writeWAV(at url: URL, seed: Int = 1) throws {
    let rate = 8000, frames = 1600
    var pcm = Data()
    for n in 0..<frames {
        var sample = Int16(sin(2 * .pi * (200.0 + Double(seed)) * Double(n) / Double(rate)) * 0.3 * 32767)
        if n == 0 { sample = Int16(truncatingIfNeeded: seed) }
        withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
    }
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    var wav = Data("RIFF".utf8)
    wav += le32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
    wav += le32(UInt32(rate)) + le32(UInt32(rate * 2)) + le16(2) + le16(16)
    wav += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
    try wav.write(to: url)
}
