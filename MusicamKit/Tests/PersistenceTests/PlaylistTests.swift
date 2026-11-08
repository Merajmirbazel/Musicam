import Testing
import Foundation
import Domain
import Sync
@testable import Persistence

@Suite struct PlaylistTests {
    private func item(_ title: String, hash: String = UUID().uuidString) -> ImportedItem {
        ImportedItem(metadata: ExtractedMetadata(title: title, artist: "A", album: "B", duration: 100,
                                                 format: AudioFormat(codec: "MP3", bitrate: 128_000)),
                     contentHash: hash, byteSize: 10, originalFilename: title + ".mp3")
    }

    @Test func createsUpdatesAndDeletes() async throws {
        let store = try LibraryStore.open(at: nil)
        let ids = try await store.add([item("one"), item("two"), item("three")]).map(\.trackID)
        let p = try await store.createPlaylist(name: "Road", trackIDs: [ids[2], ids[0]])
        #expect(try await store.allPlaylists().first?.trackIDs == [ids[2], ids[0]])

        try await store.updatePlaylist(p.id, name: "Road Trip", trackIDs: [ids[0], ids[1], ids[2]])
        let again = try await store.allPlaylists()
        #expect(again.first?.name == "Road Trip")
        #expect(again.first?.trackIDs == ids)

        try await store.deletePlaylist(p.id)
        #expect(try await store.allPlaylists().isEmpty)
    }

    @Test func playlistsReachAnotherDeviceAndLatestEditWins() async throws {
        let a = try LibraryStore.open(at: nil), b = try LibraryStore.open(at: nil)
        let ids = try await a.add([item("one", hash: "h1"), item("two", hash: "h2")]).map(\.trackID)
        let p = try await a.createPlaylist(name: "Mix", trackIDs: ids)

        try await b.ingest(try await a.changes(missingFrom: VersionVector()))
        #expect(try await b.allPlaylists().first?.name == "Mix")
        #expect(try await b.allPlaylists().first?.trackIDs == ids)

        // b reorders later; a renames earlier-than-that is overwritten only for the field it touched
        try await a.updatePlaylist(p.id, name: "Mix A")
        try await Task.sleep(for: .milliseconds(5))
        try await b.updatePlaylist(p.id, trackIDs: ids.reversed())
        try await b.ingest(try await a.changes(missingFrom: try await b.versionVector()))
        try await a.ingest(try await b.changes(missingFrom: try await a.versionVector()))

        for store in [a, b] {
            let result = try #require(try await store.allPlaylists().first)
            #expect(result.name == "Mix A")
            #expect(result.trackIDs == ids.reversed())
        }

        try await a.deletePlaylist(p.id)
        try await b.ingest(try await a.changes(missingFrom: try await b.versionVector()))
        #expect(try await b.allPlaylists().isEmpty)
    }

    @Test func playlistDeleteCanBeUndone() async throws {
        let store = try LibraryStore.open(at: nil)
        let id = try await store.add([item("one")])[0].trackID
        let p = try await store.createPlaylist(name: "Keep", trackIDs: [id])
        try await store.deletePlaylist(p.id)
        #expect(try await store.allPlaylists().isEmpty)
        try await store.restorePlaylist(p.id)
        #expect(try await store.allPlaylists().first?.trackIDs == [id])
    }

    @Test func handMadeListDropsMissingSongsAndKeepsOrder() {
        let x = Track(title: "x"), y = Track(title: "y")
        let list = Playlist(name: "L", trackIDs: [y.id, UUID(), x.id])
        #expect(list.tracks(in: [x, y]).map(\.title) == ["y", "x"])
    }
}
