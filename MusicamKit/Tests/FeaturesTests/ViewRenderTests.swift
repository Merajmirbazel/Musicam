import Testing
import SwiftUI
import Domain
@testable import Features

/// Renders real views offscreen. These catch "the panel is blank" problems that unit tests cannot.
@MainActor
@Suite struct ViewRenderTests {
    @Test func theSongEditorDrawsItsFields() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let track = try await app.addSong("Slow Tide", artist: "The Quiet Hours", album: "Saffron Skies")
        let rep = try #require(await render(TrackEditor(track: track).environment(app.model), size: CGSize(width: 280, height: 640)))
        writePNG(rep, named: "editor")
        #expect(inkFraction(rep) > 0.04, "the editor panel is blank")
    }

    @Test func theInspectorShowsTheEditorWhenOneSongIsSelected() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let track = try await app.addSong("Slow Tide")
        let rep = try #require(await render(TrackInspectorView(selection: [track.id]).environment(app.model), size: CGSize(width: 280, height: 640)))
        writePNG(rep, named: "inspector")
        #expect(inkFraction(rep) > 0.04, "the inspector is blank for a selected song")
    }

    @Test func nowPlayingShowsAnEmptyStateWithoutASong() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let rep = try #require(await render(NowPlayingView().environment(app.model), size: CGSize(width: 900, height: 600)))
        writePNG(rep, named: "nowplaying-empty")
        #expect(inkFraction(rep) > 0.003)
    }

    @Test func theSidebarListsHomeAndSongsWithTheSongCount() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        try await app.addSong("One"); try await app.addSong("Two")
        let rep = try #require(await render(SidebarView().environment(app.model), size: CGSize(width: 220, height: 400)))
        writePNG(rep, named: "sidebar")
        #expect(inkFraction(rep) > 0.01, "the sidebar is blank")
    }
}
