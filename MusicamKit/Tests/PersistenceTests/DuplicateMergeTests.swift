import Testing
import Foundation
import Domain
import Sync
@testable import Persistence

@Suite struct DuplicateMergeTests {
    private func item(_ title: String, hash: String) -> ImportedItem {
        ImportedItem(metadata: ExtractedMetadata(title: title, artist: "A", album: "B", duration: 100, format: AudioFormat(codec: "MP3")),
                     contentHash: hash, byteSize: 10, originalFilename: title + ".mp3")
    }

    private func exchange(_ a: LibraryStore, _ b: LibraryStore) async throws {
        try await b.ingest(try await a.changes(missingFrom: try await b.versionVector()))
        try await a.ingest(try await b.changes(missingFrom: try await a.versionVector()))
    }

    @Test func sameFileImportedOnTwoDevicesBecomesOneSongOnBoth() async throws {
        let a = try LibraryStore.open(at: nil), b = try LibraryStore.open(at: nil)
        _ = try await a.add([item("Song", hash: "same")])
        try await Task.sleep(for: .milliseconds(5))
        let bTrack = try await b.add([item("Song", hash: "same")])[0].trackID
        try await b.edit(trackID: bTrack, TrackEdit(rating: 5, isFavorite: true))      // the later copy was rated
        _ = try await a.add([item("Unique", hash: "other")])

        try await exchange(a, b)
        #expect(try await a.trackCount() == 3)

        let mergesA = try await a.mergeDuplicateTracks()
        let mergesB = try await b.mergeDuplicateTracks()
        #expect(mergesA.count == 1 && mergesB.count == 1)
        #expect(mergesA == mergesB)                                                   // both pick the same winner
        try await exchange(a, b)
        try await exchange(a, b)

        let songsA = try await a.allTracks().sorted { $0.title < $1.title }
        let songsB = try await b.allTracks().sorted { $0.title < $1.title }
        #expect(songsA.map(\.title) == ["Song", "Unique"])
        #expect(songsA == songsB)
        let kept = try #require(songsA.first { $0.title == "Song" })
        #expect(kept.rating == 5 && kept.isFavorite)                                  // the loser's rating and favorite survived
        #expect(try await a.mergeDuplicateTracks().isEmpty)                           // nothing left to merge
    }

    @Test func aDeviceThatHoldsTheLoserFileAnswersForTheWinner() async throws {
        let device = try DeviceStore.open(at: nil)
        let loser = UUID(), winner = UUID()
        try await device.register([LocalFileInfo(audioFileID: loser, bookmark: Data(), path: "/tmp/x.mp3", byteSize: 10, modificationDate: nil)])
        try await device.alias(winner: winner, loser: loser)
        #expect(try await device.entry(for: winner)?.path == "/tmp/x.mp3")
        #expect(try await device.presentFileIDs() == [loser, winner])
        try await device.alias(winner: UUID(), loser: UUID())                         // unknown ids: nothing happens, nothing crashes
    }
}
