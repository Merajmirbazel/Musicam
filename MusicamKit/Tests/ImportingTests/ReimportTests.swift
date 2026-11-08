import Testing
import Foundation
import Domain
import Persistence
@testable import Importing

/// The bug: add a file, delete it, and it could never be added again (it was called a duplicate, or "unchanged").
@Suite struct ReimportTests {
    private func song(_ h: Harness, _ name: String = "Again.wav", seed: Int = 7) throws -> URL {
        let url = h.dir.appendingPathComponent(name)
        try makeWAV(at: url, seed: seed)
        return url
    }

    @Test func aRemovedSongCanBeAddedAgainFromTheSamePlace() async throws {
        let h = try Harness(); defer { h.cleanup() }
        let url = try song(h)
        #expect(await h.importAll([url]).imported == 1)
        let first = try #require(try await h.library.allTracks().first)
        try await h.library.softDelete(trackIDs: [first.id])
        #expect(try await h.library.allTracks().isEmpty)

        let again = await h.importAll([url])                       // same path, same bytes: used to be "unchanged"
        #expect(again.imported == 1 && again.unchanged == 0 && again.duplicates == 0)
        let back = try await h.library.allTracks()
        #expect(back.count == 1)
        #expect(back.first?.id == first.id)                       // the same song returns, not a second copy
    }

    @Test func aRemovedSongCanBeAddedAgainFromAnotherCopy() async throws {
        let h = try Harness(); defer { h.cleanup() }
        let url = try song(h)
        _ = await h.importAll([url])
        let first = try #require(try await h.library.allTracks().first)
        try await h.library.softDelete(trackIDs: [first.id])

        let copy = h.dir.appendingPathComponent("copy/Again.wav")           // what the iPhone does: a fresh copy each time
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        let again = await h.importAll([copy])
        #expect(again.imported == 1 && again.duplicates == 0)
        #expect(try await h.library.allTracks().count == 1)
        let fileID = try #require(try await h.library.allTracks().first?.file?.id)
        let entry = try #require(try await h.device.entry(for: fileID))
        #expect(entry.state == .present)
    }

    @Test func aSongThatIsStillInTheLibraryIsStillADuplicateOrUnchanged() async throws {
        let h = try Harness(); defer { h.cleanup() }
        let url = try song(h)
        _ = await h.importAll([url])
        #expect(await h.importAll([url]).unchanged == 1)
        let copy = h.dir.appendingPathComponent("elsewhere.wav")
        try FileManager.default.copyItem(at: url, to: copy)
        #expect(await h.importAll([copy]).duplicates == 1)
        #expect(try await h.library.allTracks().count == 1)
    }

    @Test func restoringKeepsRatingsAndTheRemovedFlagSyncs() async throws {
        let h = try Harness(); defer { h.cleanup() }
        _ = await h.importAll([try song(h)])
        let t = try #require(try await h.library.allTracks().first)
        try await h.library.edit(trackID: t.id, TrackEdit(rating: 4, isFavorite: true))
        try await h.library.softDelete(trackIDs: [t.id])
        try await h.library.restore(trackIDs: [t.id])
        let back = try #require(try await h.library.allTracks().first)
        #expect(back.rating == 4 && back.isFavorite)
    }

    @Test func importsRecordWhereTheyCameFrom() async throws {
        let h = try Harness(); defer { h.cleanup() }
        let folder = h.dir.appendingPathComponent("box"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeWAV(at: folder.appendingPathComponent("InFolder.wav"), seed: 1)
        let single = try song(h, "Single.wav", seed: 2)
        let telegram = try song(h, "FromTelegram.wav", seed: 3)
        _ = await h.importAll([folder])
        _ = await h.importAll([single])
        _ = await h.importAll([telegram], source: TrackSource.telegram.raw)
        let by = Dictionary(uniqueKeysWithValues: try await h.library.allTracks().map { ($0.title, $0.file?.source ?? "") })
        #expect(by["InFolder"] == "folder")
        #expect(by["Single"] == "file")
        #expect(by["FromTelegram"] == "telegram")
        #expect(TrackSource(raw: "link:archive.org") == .link(host: "archive.org"))
        #expect(TrackSource(raw: "").isDownloaded == false && TrackSource.telegram.isDownloaded && !TrackSource.file.isDownloaded)
        #expect(TrackSource.forWatchedFolder(path: "/Users/a/Downloads/Telegram Desktop") == .telegram)
        #expect(TrackSource.forWatchedFolder(path: "/Users/a/Music/New") == .watched)
    }
}
