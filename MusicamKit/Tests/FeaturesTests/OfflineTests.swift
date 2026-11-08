import Testing
import Foundation
import Domain
import Persistence
@testable import Features

@Suite struct OfflinePlannerTests {
    private func track(_ title: String, size: Int64 = 1_000_000, fav: Bool = false) -> Track {
        Track(title: title, isFavorite: fav,
              file: AudioFileInfo(contentHash: title, byteSize: size, originalFilename: title, format: AudioFormat(codec: "MP3"), duration: 1))
    }

    @Test func disabledDoesNothing() {
        let t = track("a", fav: true)
        let plan = OfflinePlanner.plan(settings: OfflineSettings(), tracks: [t], playlists: [], present: [], fetched: [])
        #expect(plan.toDownload.isEmpty && plan.toEvict.isEmpty)
    }

    @Test func wantsFavoritesCollectionsAndPlaylistsWithoutRepeats() {
        let a = track("a", fav: true), b = track("b"), c = track("c")
        var s = OfflineSettings(); s.enabled = true
        let list = Playlist(name: "P", trackIDs: [b.id, a.id])
        s.playlists = [list.id]
        let plan = OfflinePlanner.plan(settings: s, tracks: [a, b, c], playlists: [list], present: [], fetched: [])
        #expect(plan.toDownload.map(\.title) == ["a", "b"])                // c is not wanted, a only once
        let already = OfflinePlanner.plan(settings: s, tracks: [a, b, c], playlists: [list], present: [a.file!.id], fetched: [])
        #expect(already.toDownload.map(\.title) == ["b"])
    }

    @Test func limitSkipsWhatDoesNotFitAndEvictsOldestFetchedFirst() {
        let a = track("a", size: 6_000_000, fav: true), b = track("b", size: 6_000_000, fav: true), c = track("c", size: 3_000_000, fav: true)
        var s = OfflineSettings(); s.enabled = true; s.limitMegabytes = 10
        let old = FetchedFile(id: UUID(), size: 4_000_000, date: Date(timeIntervalSince1970: 100))
        let newer = FetchedFile(id: UUID(), size: 4_000_000, date: Date(timeIntervalSince1970: 200))
        let plan = OfflinePlanner.plan(settings: s, tracks: [a, b, c], playlists: [], present: [], fetched: [newer, old])
        #expect(plan.toDownload.map(\.title) == ["a", "c"])               // b would not fit
        #expect(plan.toEvict == [old.id, newer.id])                       // 9 MB incoming + 8 MB held > 10 MB: oldest go first
    }

    @Test func fetchedCopiesThatAreWantedAreNeverEvicted() {
        let a = track("a", size: 6_000_000, fav: true)
        var s = OfflineSettings(); s.enabled = true; s.limitMegabytes = 7
        let wanted = FetchedFile(id: a.file!.id, size: 6_000_000, date: .distantPast)
        let plan = OfflinePlanner.plan(settings: s, tracks: [a], playlists: [], present: [a.file!.id], fetched: [wanted])
        #expect(plan.toEvict.isEmpty)
    }

    @Test func noLimitMeansNothingIsEverRemoved() {
        var s = OfflineSettings(); s.enabled = true
        let plan = OfflinePlanner.plan(settings: s, tracks: [], playlists: [], present: [],
                                       fetched: [FetchedFile(id: UUID(), size: 1_000_000_000, date: .now)])
        #expect(plan.toEvict.isEmpty)
    }
}

@MainActor
@Suite struct OfflineModelTests {
    private func defaults() -> OfflineSettingsStore {
        let d = UserDefaults(suiteName: "musicam-test-\(UUID().uuidString)")!
        return OfflineSettingsStore(defaults: d)
    }

    @Test func downloadsWantedSongsOnlyWhileAnotherDeviceIsReachable() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let fav = try await app.addSong("Fav", hash: "h1")
        try await app.addSong("Other", hash: "h2")
        await app.model.library.edit(fav.id, TrackEdit(isFavorite: true))

        var fetched: [LibraryFileID] = []
        var connected = false
        let media = app.dir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let model = OfflineModel(library: app.model.library, playlists: app.model.playlists, device: app.device, mediaDirectory: media,
                                 store: defaults(),
                                 fetch: { id in
                                     fetched.append(id)
                                     let url = media.appendingPathComponent(id.uuidString + ".mp3")
                                     try Data("x".utf8).write(to: url)
                                     try await app.device.register([LocalFileInfo(audioFileID: id, bookmark: Data(), path: url.path, byteSize: 1, modificationDate: nil)])
                                 },
                                 isConnected: { connected })
        await model.reconcile()
        #expect(model.state == .off && fetched.isEmpty)

        model.settings.enabled = true
        await model.reconcile()
        #expect(model.state == .waiting && fetched.isEmpty)

        connected = true
        await model.reconcile()
        #expect(fetched == [try #require(fav.file?.id)])
        #expect(model.state == .idle)
        #expect(app.model.library.isStoredHere(try #require(app.model.library.track(id: fav.id))))

        await model.reconcile()                      // nothing left to do
        #expect(fetched.count == 1)
    }

    @Test func freesFetchedSongsOverTheLimitButKeepsImportedOnes() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let fetchedSong = try await app.addSong("Fetched", hash: "f1")
        let ownSong = try await app.addSong("Own", hash: "o1")
        let media = app.dir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let fetchedURL = media.appendingPathComponent("fetched.mp3")
        let ownURL = app.dir.appendingPathComponent("own.mp3")
        try Data(count: 3_000_000).write(to: fetchedURL)
        try Data(count: 3_000_000).write(to: ownURL)
        try await app.device.register([
            LocalFileInfo(audioFileID: fetchedSong.file!.id, bookmark: Data(), path: fetchedURL.path, byteSize: 3_000_000, modificationDate: nil),
            LocalFileInfo(audioFileID: ownSong.file!.id, bookmark: Data(), path: ownURL.path, byteSize: 3_000_000, modificationDate: nil),
        ])
        let store = defaults()
        var s = OfflineSettings(); s.enabled = true; s.limitMegabytes = 1
        store.save(s)
        let model = OfflineModel(library: app.model.library, playlists: app.model.playlists, device: app.device, mediaDirectory: media,
                                 store: store, fetch: { _ in }, isConnected: { true })
        await model.reconcile()
        #expect(!FileManager.default.fileExists(atPath: fetchedURL.path))
        #expect(FileManager.default.fileExists(atPath: ownURL.path))
        #expect(try await app.device.presentFileIDs() == [ownSong.file!.id])
        #expect(model.freedBytes == 3_000_000)
    }
}
