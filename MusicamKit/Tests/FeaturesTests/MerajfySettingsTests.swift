import Testing
import Foundation
import Importing
import Metadata
import Acquisition
@testable import Features

@MainActor
@Suite struct MerajfySettingsTests {
    private func defaults() -> UserDefaults {
        let name = "merajfy-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private struct FakeFetcher: LinkInfoFetching {
        func info(for kind: LinkKind) async throws -> LinkInfo { LinkInfo(title: "Never Gonna Give You Up", artist: "Rick Astley") }
    }

    @Test func isOnByDefaultAndSavesEveryChange() {
        let d = defaults()
        let s = MerajfySettings(defaults: d)
        #expect(s.isEnabled)                                  // on by default
        s.isEnabled = false
        #expect(s.config == nil && s.store.current == nil)    // off means no config, whatever else is set
        s.address = "192.168.1.20:8787"
        s.token = "abc"
        s.format = "m4a"
        s.isEnabled = true
        #expect(s.config == MerajfyConfig(baseURL: URL(string: "http://192.168.1.20:8787")!, token: "abc", format: "m4a"))
        #expect(s.store.current == s.config)

        let again = MerajfySettings(defaults: d)               // survives a restart
        #expect(again.isEnabled && again.address == "192.168.1.20:8787" && again.token == "abc" && again.format == "m4a")
        again.isEnabled = false
        #expect(again.store.current == nil)
    }

    @Test func anUnusableAddressOrFormatFallsBackSafely() {
        let d = defaults()
        d.set("zip", forKey: "musicam.merajfy.format")
        let s = MerajfySettings(defaults: d)
        #expect(s.format == "mp3")
        s.isEnabled = true
        s.address = "   "
        #expect(s.config == nil)
    }

    /// With Merajfy off a Spotify link is still only remembered by name, exactly as before.
    @Test func spotifyLinksStayOnTheWishlistWhileMerajfyIsOff() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let settings = MerajfySettings(defaults: defaults())
        settings.isEnabled = false
        let manager = AcquisitionManager(registry: .standard(downloadsDirectory: app.dir.appendingPathComponent("dl"), merajfy: settings.store),
                                         handoff: { _ in Issue.record("nothing must be downloaded") })
        let m = WishlistModel(store: WishlistStore(url: nil), fetcher: FakeFetcher(),
                              downloader: DirectAudioDownloader(directory: app.dir.appendingPathComponent("dl")),
                              importFiles: { _, _ in }, acquisition: manager)
        #expect(await m.submit("https://open.spotify.com/track/1") == .wishlisted("Never Gonna Give You Up"))
        #expect(m.items.count == 1)
    }

    /// With Merajfy on but nothing listening, the person gets the reason, and the wish list is not touched.
    @Test func whenOnAndUnreachableTheLinkReportsWhy() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let settings = MerajfySettings(defaults: defaults())
        settings.address = "127.0.0.1:1"            // nothing listens here
        settings.isEnabled = true
        let manager = AcquisitionManager(registry: .standard(downloadsDirectory: app.dir.appendingPathComponent("dl"), merajfy: settings.store),
                                         handoff: { _ in Issue.record("nothing must be imported") })
        let m = WishlistModel(store: WishlistStore(url: nil), fetcher: FakeFetcher(),
                              downloader: DirectAudioDownloader(directory: app.dir.appendingPathComponent("dl")),
                              importFiles: { _, _ in }, acquisition: manager)
        guard case .failed(let reason) = await m.submit("https://open.spotify.com/track/1") else { Issue.record("expected a failure"); return }
        #expect(reason.contains("Merajfy"))
        #expect(m.items.isEmpty)
    }
}
