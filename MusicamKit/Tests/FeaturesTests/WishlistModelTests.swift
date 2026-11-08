import Testing
import Foundation
import Domain
import Importing
import Metadata
import Acquisition
@testable import Features

@MainActor
@Suite struct WishlistModelTests {
    private struct FakeFetcher: LinkInfoFetching {
        func info(for kind: LinkKind) async throws -> LinkInfo { LinkInfo(title: "Night Walk", artist: "Kian") }
    }

    private func model(_ app: TestApp, imported: @escaping @MainActor ([URL], String?) -> Void = { _, _ in }) -> WishlistModel {
        WishlistModel(store: WishlistStore(url: nil), fetcher: FakeFetcher(),
                      downloader: DirectAudioDownloader(directory: app.dir.appendingPathComponent("dl")), importFiles: imported)
    }

    @Test func spotifyAndYouTubeLinksBecomeWishesAndAreTickedOffByTheLibrary() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let m = model(app)
        #expect(await m.submit("https://open.spotify.com/track/1") == .wishlisted("Night Walk"))
        #expect(await m.submit("https://open.spotify.com/track/1") == .alreadyListed)
        #expect(await m.submit("https://youtu.be/abc") == .wishlisted("Night Walk"))
        #expect(m.items.count == 2)
        #expect(m.pendingCount(in: app.model.library.tracks) == 2)

        try await app.addSong("night walk", artist: "Kian")                 // the file arrives lawfully and is imported
        #expect(m.pendingCount(in: app.model.library.tracks) == 0)
        #expect(m.match(for: m.items[0], in: app.model.library.tracks)?.title == "night walk")

        await m.remove(m.items[0].id)
        #expect(m.items.count == 1)
    }

    @Test func streamingServicesAndNonLinksAreRefused() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let m = model(app)
        #expect(await m.submit("https://soundcloud.com/a/b") == .unsupported("soundcloud.com"))
        if case .failed = await m.submit("just some words") {} else { Issue.record("expected failure") }
        #expect(m.items.isEmpty)
    }

    private struct OneFileProvider: MediaProvider {
        let id = "test"
        let displayName = "test"
        let folder: URL
        var fail = false
        func canHandle(_ request: AcquisitionRequest) -> Bool { true }
        func acquire(_ request: AcquisitionRequest, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile] {
            if fail { throw AcquisitionError.failed(provider: id, reason: "no good", retryable: false) }
            let dir = folder.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("a.mp3")
            try Data("abc".utf8).write(to: file)
            return [AcquiredFile(url: file, source: "link:example.org", providerID: id, ownsFolder: true)]
        }
    }

    private final class Handed: @unchecked Sendable { var sources: [String] = [] }

    @Test func directAudioLinksGoThroughTheAcquisitionLayerWhenItIsConnected() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let handed = Handed()
        let manager = AcquisitionManager(registry: try ProviderRegistry([OneFileProvider(folder: app.dir.appendingPathComponent("acq"))]),
                                         handoff: { files in await MainActor.run { handed.sources += files.map(\.source) } })
        let m = WishlistModel(store: WishlistStore(url: nil), fetcher: FakeFetcher(),
                              downloader: DirectAudioDownloader(directory: app.dir.appendingPathComponent("dl")),
                              importFiles: { _, _ in Issue.record("the old path must not be used") }, acquisition: manager)
        #expect(await m.submit("https://example.org/files/a.mp3") == .imported("a.mp3"))
        #expect(handed.sources == ["link:example.org"])
        #expect(m.items.isEmpty)                                    // a file link is not a wish
    }

    @Test func acquisitionFailuresKeepTheirMessage() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let manager = AcquisitionManager(registry: try ProviderRegistry([OneFileProvider(folder: app.dir, fail: true)]), handoff: { _ in })
        let m = WishlistModel(store: WishlistStore(url: nil), fetcher: FakeFetcher(),
                              downloader: DirectAudioDownloader(directory: app.dir.appendingPathComponent("dl")),
                              importFiles: { _, _ in }, acquisition: manager)
        #expect(await m.submit("https://example.org/a.mp3") == .failed("no good"))
        // spotify links are still wishes, never downloads
        #expect(await m.submit("https://open.spotify.com/track/1") == .wishlisted("Night Walk"))
    }
}
