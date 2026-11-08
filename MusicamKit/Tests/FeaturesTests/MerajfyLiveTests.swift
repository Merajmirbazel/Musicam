import Testing
import Foundation
import Domain
import Importing
import Metadata
import Acquisition
@testable import Features

/// Real end to end: needs Merajfy running on this Mac (127.0.0.1:8787) and internet. Skipped unless you ask for it:
///   MERAJFY_LIVE=1 swift test --filter MerajfyLiveTests
@MainActor
@Suite struct MerajfyLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MERAJFY_LIVE"] != nil))
    func aSpotifyLinkIsDownloadedByMerajfyAndLandsInTheLibrary() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let settings = app.model.merajfy
        let saved = (settings.isEnabled, settings.address, settings.token, settings.format)
        defer { (settings.isEnabled, settings.address, settings.token, settings.format) = saved }
        settings.address = "127.0.0.1:8787"
        settings.format = "mp3"
        settings.isEnabled = true

        await settings.testConnection()
        #expect(settings.status == .ok("Merajfy is ready."))

        let outcome = await app.model.wishlist.submit("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8")
        guard case .imported(let name) = outcome else { Issue.record("expected an import, got \(outcome)"); return }
        #expect(name.contains("Never Gonna Give You Up"))

        // the importer runs in the background; wait for the song to appear
        let deadline = Date().addingTimeInterval(30)
        while app.model.library.tracks.isEmpty && Date() < deadline {
            await app.model.library.load()
            try await Task.sleep(for: .milliseconds(200))
        }
        let track = try #require(app.model.library.tracks.first)
        print("LIVE RESULT: title=\(track.title) artist=\(track.artist) album=\(track.album)")
        #expect(track.title.localizedCaseInsensitiveContains("Never Gonna Give You Up"))
        #expect(track.artist.localizedCaseInsensitiveContains("Rick Astley"))
        #expect(app.model.wishlist.items.isEmpty)       // downloaded, not just wished for
    }
}
