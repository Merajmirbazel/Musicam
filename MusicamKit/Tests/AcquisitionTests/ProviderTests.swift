import Testing
import Foundation
import Synchronization
import Metadata
@testable import Acquisition

@Suite struct DirectAudioProviderTests {
    @Test func onlyAcceptsLinksToAudioFiles() {
        let p = DirectAudioProvider(directory: makeScratchFolder())
        #expect(p.canHandle(.link(URL(string: "https://example.org/files/My%20Song.mp3")!)))
        #expect(p.canHandle(.link(URL(string: "https://example.org/a.flac")!)))
        #expect(!p.canHandle(.link(URL(string: "https://open.spotify.com/track/1")!)))
        #expect(!p.canHandle(.link(URL(string: "https://www.youtube.com/watch?v=abc")!)))
        #expect(!p.canHandle(.link(URL(string: "https://example.org/page.html")!)))
        #expect(!p.canHandle(AcquisitionRequest(query: "song")))
    }

    @Test func downloadsIntoAFolderOfItsOwnAndRecordsTheSource() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let server = StubServer()
        let p = DirectAudioProvider(directory: dir, session: server.session)
        let files = try await p.acquire(.link(URL(string: "https://www.example.org/files/My%20Song.mp3")!)) { _ in }
        let file = try #require(files.first)
        #expect(file.url.lastPathComponent == "My Song.mp3")
        #expect(file.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)   // directory/<folder>/<file>
        #expect(file.source == "link:example.org")
        #expect(file.ownsFolder)
        #expect(file.problem == nil)
    }

    @Test func webPagesAndServerErrorsAreExplained() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let server = StubServer()
        let p = DirectAudioProvider(directory: dir, session: server.session)
        let url = URL(string: "https://example.org/song.mp3")!
        server.respond { _ in (200, "text/html", Data("<html>".utf8)) }
        do { _ = try await p.acquire(.link(url)) { _ in }; Issue.record("expected a failure") }
        catch let e as AcquisitionError { #expect(!e.isRetryable); guard case .failed("direct-audio", _, false) = e else { Issue.record("wrong error \(e)"); return } }
        server.respond { _ in (503, "audio/mpeg", Data()) }
        do { _ = try await p.acquire(.link(url)) { _ in }; Issue.record("expected a failure") }
        catch let e as AcquisitionError { #expect(e.isRetryable) }
        server.respond { _ in (404, "audio/mpeg", Data()) }
        do { _ = try await p.acquire(.link(url)) { _ in }; Issue.record("expected a failure") }
        catch let e as AcquisitionError { #expect(!e.isRetryable) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)      // nothing left behind
    }
}

private struct StubListing: ArchiveListing {
    var files: [ArchiveFile]
    func files(of identifier: String) async throws -> [ArchiveFile] { files }
}

private func archiveFile(_ name: String) -> ArchiveFile {
    ArchiveFile(name: name, size: 3, url: URL(string: "https://archive.org/download/abc/\(name)")!)
}

@Suite struct InternetArchiveProviderTests {
    @Test func recognisesItsOwnLinksOnly() {
        let p = InternetArchiveProvider(directory: makeScratchFolder(), listing: StubListing(files: []))
        #expect(p.canHandle(.link(URL(string: "https://archive.org/download/abc/01%20Song.mp3")!)))
        #expect(p.canHandle(.link(URL(string: "https://archive.org/details/abc")!)))
        #expect(p.canHandle(.link(URL(string: "https://www.archive.org/details/abc")!)))
        #expect(!p.canHandle(.link(URL(string: "https://archive.org/about/")!)))
        #expect(!p.canHandle(.link(URL(string: "https://archive.org/download/abc/cover.jpg")!)))
        #expect(!p.canHandle(.link(URL(string: "https://example.org/download/abc/a.mp3")!)))
        #expect(InternetArchiveProvider.target(for: URL(string: "https://archive.org/details/abc")!) == .item("abc"))
    }

    @Test func aFileLinkDownloadsThatFile() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = InternetArchiveProvider(directory: dir, listing: StubListing(files: []), session: StubServer().session)
        let files = try await p.acquire(.link(URL(string: "https://archive.org/download/abc/01%20Song.mp3")!)) { _ in }
        #expect(files.count == 1)
        #expect(files[0].url.lastPathComponent == "01 Song.mp3")
        #expect(files[0].source == "link:archive.org")
        #expect(files[0].providerID == "internet-archive")
    }

    @Test func anItemLinkDownloadsItsSongsUpToTheLimitAndReportsProgress() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let listing = StubListing(files: ["1.mp3", "2.mp3", "3.mp3"].map(archiveFile))
        let p = InternetArchiveProvider(directory: dir, listing: listing, session: StubServer().session, maxFiles: 2)
        let seen = LockedList()
        let files = try await p.acquire(.link(URL(string: "https://archive.org/details/abc")!)) { seen.add($0.fraction) }
        #expect(files.map { $0.url.lastPathComponent } == ["1.mp3", "2.mp3"])
        #expect(seen.values.contains(0) && seen.values.contains(0.5) && seen.values.last == 1)
    }

    @Test func halfwayFailureKeepsTheSongsThatArrivedButFirstFailureFails() async throws {
        let dir = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let listing = StubListing(files: ["1.mp3", "2.mp3"].map(archiveFile))
        let server = StubServer()
        let p = InternetArchiveProvider(directory: dir, listing: listing, session: server.session)
        let item = AcquisitionRequest.link(URL(string: "https://archive.org/details/abc")!)

        server.respond { request in request.url!.lastPathComponent == "2.mp3" ? (404, "audio/mpeg", Data()) : (200, "audio/mpeg", Data("abc".utf8)) }
        #expect(try await p.acquire(item) { _ in }.map { $0.url.lastPathComponent } == ["1.mp3"])

        server.respond { _ in (404, "audio/mpeg", Data()) }
        await #expect(throws: AcquisitionError.self) { _ = try await p.acquire(item) { _ in } }
    }

    @Test func anItemWithoutAudioIsAnExplainedFailure() async throws {
        let p = InternetArchiveProvider(directory: makeScratchFolder(), listing: StubListing(files: []))
        do { _ = try await p.acquire(.link(URL(string: "https://archive.org/details/abc")!)) { _ in }; Issue.record("expected a failure") }
        catch let e as AcquisitionError { #expect(!e.isRetryable) }
    }
}

final class LockedList: Sendable {
    private let storage = Mutex<[Double]>([])
    func add(_ value: Double?) { if let value { storage.withLock { $0.append(value) } } }
    var values: [Double] { storage.withLock { $0 } }
}
