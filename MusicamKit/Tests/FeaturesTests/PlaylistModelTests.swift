import Testing
import Foundation
import Domain
@testable import Features

@MainActor
@Suite struct PlaylistModelTests {
    @Test func buildsReordersAndTrimsAPlaylist() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let a = try await app.addSong("A"), b = try await app.addSong("B"), c = try await app.addSong("C")
        let pl = app.model.playlists
        let list = try #require(await pl.create(name: "  Mix  ", tracks: [a.id]))
        #expect(pl.playlist(id: list.id)?.name == "Mix")

        await pl.add([a.id, b.id, c.id], to: list.id)           // a is already in, not repeated
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["A", "B", "C"])

        await pl.move(in: list.id, from: IndexSet(integer: 2), to: 0)
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["C", "A", "B"])
        await pl.move(in: list.id, from: IndexSet(integer: 0), to: 3)
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["A", "B", "C"])

        await pl.remove([b.id], from: list.id)
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["A", "C"])

        await pl.rename(list.id, to: "Road")
        #expect(pl.playlist(id: list.id)?.name == "Road")
        await pl.delete(list.id)
        #expect(pl.playlists.isEmpty)
    }

    @Test func emptyNamesAreRefused() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let a = try await app.addSong("A")
        let pl = app.model.playlists
        #expect(await pl.create(name: "   ") == nil)
    }

    @Test func favoritesAreTheHeartedSongs() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let a = try await app.addSong("A")
        try await app.addSong("B")
        await app.model.library.edit(a.id, TrackEdit(isFavorite: true))
        #expect(app.model.playlists.favorites.map(\.title) == ["A"])
    }

    @Test func playlistSummaryShowsCountAndTotalTime() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let a = try await app.addSong("A"), b = try await app.addSong("B")       // 200 seconds each
        let pl = app.model.playlists
        let list = try #require(await pl.create(name: "Two", tracks: [a.id, b.id]))
        let text = pl.summary(of: pl.playlist(id: list.id)!)
        #expect(text.contains("2"))
        #expect(text.contains("6"))            // 400 s = 6 min 40 s
        #expect(formatLongDuration(3725).contains("1"))
        #expect(!formatLongDuration(0).isEmpty)
    }
}
