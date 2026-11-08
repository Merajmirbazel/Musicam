import Testing
import Foundation
import Domain
@testable import Persistence

private func item(_ title: String, hash: String, artist: String = "Artist") -> ImportedItem {
    ImportedItem(
        metadata: ExtractedMetadata(title: title, artist: artist, album: "Album", duration: 180,
                                    format: AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2, isLossless: true)),
        contentHash: hash, byteSize: 1_000, originalFilename: title + ".flac")
}

@Suite struct LibraryStoreTests {
    @Test func addedTracksComeBackAsSnapshotsWithTheirFile() async throws {
        let store = try LibraryStore.open(at: nil)
        let results = try await store.add([item("One", hash: "h1"), item("Two", hash: "h2")])
        #expect(results.map(\.wasDuplicate) == [false, false])

        let tracks = try await store.allTracks()
        #expect(tracks.count == 2)
        let one = try #require(tracks.first { $0.title == "One" })
        #expect(one.file?.contentHash == "h1")
        #expect(one.file?.format.summary == "FLAC · 24-bit · 96 kHz")
    }

    @Test func sameContentHashIsADuplicateEvenAcrossBatches() async throws {
        let store = try LibraryStore.open(at: nil)
        let first = try await store.add([item("One", hash: "same")])
        let again = try await store.add([item("Renamed copy", hash: "same")])
        #expect(again[0].wasDuplicate)
        #expect(again[0].trackID == first[0].trackID)
        #expect(try await store.trackCount() == 1)
    }

    @Test func duplicatesInsideOneBatchAreCaught() async throws {
        let store = try LibraryStore.open(at: nil)
        let r = try await store.add([item("A", hash: "x"), item("A copy", hash: "x"), item("B", hash: "y")])
        #expect(r.map(\.wasDuplicate) == [false, true, false])
        #expect(try await store.trackCount() == 2)
    }

    @Test func editChangesOnlyTheGivenFieldsAndClampsRating() async throws {
        let store = try LibraryStore.open(at: nil)
        let id = try await store.add([item("Old title", hash: "h")])[0].trackID
        let edited = try await store.edit(trackID: id, TrackEdit(title: "New title", rating: 9, isFavorite: true))
        #expect(edited?.title == "New title")
        #expect(edited?.artist == "Artist")
        #expect(edited?.rating == 5)
        #expect(edited?.isFavorite == true)
    }

    @Test func softDeletedTracksDisappearButStayInTheStore() async throws {
        let store = try LibraryStore.open(at: nil)
        let id = try await store.add([item("Gone", hash: "g"), item("Stays", hash: "s")])[0].trackID
        try await store.softDelete(trackIDs: [id])
        #expect(try await store.trackCount() == 1)
        #expect(try await store.allTracks().map(\.title) == ["Stays"])
        // The same file added again after deletion brings the same song back. (It used to be reported as a duplicate of
        // a song that no longer exists, which made it impossible to add a removed file again.)
        let again = try await store.add([item("Gone", hash: "g")])[0]
        #expect(!again.wasDuplicate && again.trackID == id)
        #expect(try await store.allTracks().map(\.title).sorted() == ["Gone", "Stays"])
        #expect(try await store.add([item("Gone", hash: "g")])[0].wasDuplicate)      // now it really is a duplicate
    }

    @Test func storePersistsOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.store")
        do {
            let store = try LibraryStore.open(at: url)
            try await store.add([item("Persisted", hash: "p")])
        }
        let reopened = try LibraryStore.open(at: url)
        #expect(try await reopened.allTracks().map(\.title) == ["Persisted"])
    }
}

@Suite struct DeviceStoreAndAccessTests {
    private func tempFile(_ name: String = "song.bin") throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data(repeating: 7, count: 2048).write(to: file)
        return (dir, file)
    }

    @Test func registeredFileCanBeOpenedThroughItsBookmark() async throws {
        let (dir, file) = try tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let device = try DeviceStore.open(at: nil)
        let id = UUID()
        let bookmark = try file.bookmarkData(options: .withSecurityScope)
        try await device.register([LocalFileInfo(audioFileID: id, bookmark: bookmark, path: file.path, byteSize: 2048, modificationDate: nil)])

        let access = try await FileAccessService(device: device).open(id)
        #expect(access.url.lastPathComponent == "song.bin")
        #expect(try Data(contentsOf: access.url).count == 2048)
        access.release()
        access.release()   // releasing twice is harmless
    }

    @Test func aDeletedFileIsReportedMissingAndMarkedSo() async throws {
        let (dir, file) = try tempFile()
        let device = try DeviceStore.open(at: nil)
        let id = UUID()
        try await device.register([LocalFileInfo(audioFileID: id, bookmark: try file.bookmarkData(options: .withSecurityScope),
                                                 path: file.path, byteSize: 2048, modificationDate: nil)])
        try FileManager.default.removeItem(at: dir)

        await #expect(throws: FileAccessError.missing(id)) {
            _ = try await FileAccessService(device: device).open(id)
        }
        #expect(try await device.entry(for: id)?.state == .missing)
    }

    @Test func unknownFileIDIsNotRegistered() async throws {
        let device = try DeviceStore.open(at: nil)
        let id = UUID()
        await #expect(throws: FileAccessError.notRegistered(id)) {
            _ = try await FileAccessService(device: device).open(id)
        }
    }

    @Test func knownFilesAreIndexedByPath() async throws {
        let device = try DeviceStore.open(at: nil)
        let id = UUID()
        try await device.register([LocalFileInfo(audioFileID: id, bookmark: Data([1]), path: "/a/b.flac", byteSize: 5, modificationDate: nil)])
        #expect(try await device.knownFilesByPath()["/a/b.flac"]?.audioFileID == id)
    }
}

@Suite struct WatchedFolderStoreTests {
    @Test func foldersAreAddedOnceRemovedAndListedInOrder() async throws {
        let device = try DeviceStore.open(at: nil)
        try await device.addWatchedFolder(WatchedFolder(path: "/a", bookmark: Data([1])))
        try await device.addWatchedFolder(WatchedFolder(path: "/b", bookmark: Data([2])))
        try await device.addWatchedFolder(WatchedFolder(path: "/a", bookmark: Data([9])))      // again: refreshed, not duplicated
        let all = try await device.watchedFolders()
        #expect(all.map(\.path) == ["/a", "/b"])
        #expect(all[0].bookmark == Data([9]))
        try await device.removeWatchedFolder(path: "/a")
        #expect(try await device.watchedFolders().map(\.path) == ["/b"])
    }
}
