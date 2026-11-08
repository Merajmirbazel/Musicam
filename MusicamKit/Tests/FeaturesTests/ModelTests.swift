import Testing
import Foundation
import Domain
import Importing
import Peering
@testable import Features

@MainActor
@Suite struct LibraryModelTests {
    @Test func searchFiltersByTitleArtistAndAlbumIgnoringCaseAndAccents() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        try await app.addSong("Late Night Drive", artist: "Nova Lane", album: "City Static")
        try await app.addSong("Café Blue", artist: "Marlow", album: "Weekdays")
        try await app.addSong("نیمه‌شب", artist: "گروه نمونه", album: "شب‌نامه")

        let order = [KeyPathComparator(\Track.title)]
        #expect(app.model.library.visible(search: "", sortOrder: order).count == 3)
        #expect(app.model.library.visible(search: "NOVA", sortOrder: order).map(\.title) == ["Late Night Drive"])
        #expect(app.model.library.visible(search: "cafe", sortOrder: order).map(\.title) == ["Café Blue"])
        #expect(app.model.library.visible(search: "weekdays", sortOrder: order).count == 1)
        #expect(app.model.library.visible(search: "نیمه", sortOrder: order).count == 1)
        #expect(app.model.library.visible(search: "no such song", sortOrder: order).isEmpty)
    }

    @Test func sortingFollowsTheRequestedOrder() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        for title in ["banana", "Apple", "cherry"] { try await app.addSong(title) }
        let ascending = app.model.library.visible(search: "", sortOrder: [KeyPathComparator(\Track.title)])
        #expect(ascending.map(\.title) == ["Apple", "banana", "cherry"])
        let descending = app.model.library.visible(search: "", sortOrder: [KeyPathComparator(\Track.title, order: .reverse)])
        #expect(descending.map(\.title) == ["cherry", "banana", "Apple"])
    }

    @Test func importingFilesAddsThemAndReportsAFinishedMessage() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let folder = app.dir.appendingPathComponent("songs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 1...3 { try makeWAV(at: folder.appendingPathComponent("Song \(i).wav"), seed: i) }

        app.model.library.startImport([folder])
        for _ in 0..<200 {
            if case .finished = app.model.library.importState { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .finished(let summary) = app.model.library.importState else {
            Issue.record("import never finished"); return
        }
        #expect(summary.imported == 3)
        #expect(app.model.library.tracks.count == 3)
        #expect(ImportState.message(for: summary) == "Added 3 songs.")
        app.model.library.dismissImportMessage()
        #expect(app.model.library.importState == .idle)
    }

    @Test func editingATrackUpdatesTheVisibleSnapshot() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let track = try await app.addSong("Wrong title")
        await app.model.library.edit(track.id, TrackEdit(title: "Right title", rating: 4))
        let updated = try #require(app.model.library.track(id: track.id))
        #expect(updated.title == "Right title")
        #expect(updated.rating == 4)
    }

    @Test func removingTracksHidesThemAndKeepsOthers() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let gone = try await app.addSong("Gone")
        try await app.addSong("Stays")
        await app.model.library.remove([gone.id])
        #expect(app.model.library.tracks.map(\.title) == ["Stays"])
        await app.model.library.load()          // a reload from the store agrees
        #expect(app.model.library.tracks.map(\.title) == ["Stays"])
    }

    @Test func recentlyAddedIsNewestFirstAndLimited() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        for i in 1...5 { try await app.addSong("Song \(i)"); try await Task.sleep(for: .milliseconds(5)) }
        #expect(app.model.library.recentlyAdded(limit: 3).map(\.title) == ["Song 5", "Song 4", "Song 3"])
    }
}

@Suite struct FormattingTests {
    @Test func timeFormatting() {
        #expect(formatTime(0) == "0:00")
        #expect(formatTime(-5) == "0:00")
        #expect(formatTime(.nan) == "0:00")
        #expect(formatTime(65) == "1:05")
        #expect(formatTime(3599) == "59:59")
        #expect(formatTime(3725) == "1:02:05")
    }

    @Test func importMessages() {
        #expect(ImportState.message(for: ImportSummary()) == "No audio files found.")
        var s = ImportSummary(); s.imported = 1
        // the "song"/"songs" choice comes from the app's string catalog, which the package tests do not load
        #expect(ImportState.message(for: s).hasPrefix("Added 1 song"))
        s.duplicates = 2; s.failed = 1; s.unsupported = 1
        #expect(ImportState.message(for: s).contains("2 already in your library"))
        #expect(ImportState.message(for: s).contains("Ogg"))
        #expect(ImportState.message(for: s).contains("1 could not be read"))
    }
}

@MainActor
@Suite struct SyncModelTests {
    private func make(store: MemoryPairingStore = MemoryPairingStore()) throws -> (SyncModel, MemoryPairingStore, TestApp) {
        let app = try TestApp.make()
        let model = SyncModel(pairing: store, networking: false) { key in
            SyncEngine(library: app.library, device: app.device, key: key, deviceName: "T", mediaDirectory: app.dir.appendingPathComponent("m"))
        }
        return (model, store, app)
    }

    @Test func creatingAPairingMakesACodeAndRemembersIt() async throws {
        let (model, store, app) = try make()
        defer { app.cleanup() }
        let code = await model.createPairing()
        #expect(model.isPaired)
        #expect(model.pairingCode == code)
        #expect(PairingKey(code: code) != nil)
        #expect(store.load()?.code == code)
    }

    @Test func joiningWithAValidCodeSharesTheSameSecret() async throws {
        let (first, _, a1) = try make()
        let (second, store2, a2) = try make()
        defer { a1.cleanup(); a2.cleanup() }
        let code = await first.createPairing()
        let ok = await second.join(code: code.uppercased().replacingOccurrences(of: "-", with: " "))
        #expect(ok)
        #expect(store2.load() == PairingKey(code: code))
    }

    @Test func anInvalidCodeIsRefusedWithAMessage() async throws {
        let (model, store, app) = try make()
        defer { app.cleanup() }
        #expect(await model.join(code: "not a code") == false)
        #expect(model.joinError != nil)
        #expect(!model.isPaired)
        #expect(store.load() == nil)
    }

    @Test func aPairedDeviceResumesAtLaunchAndForgettingClearsEverything() async throws {
        let key = PairingKey.generate()
        let (model, store, app) = try make(store: MemoryPairingStore(key: key))
        defer { app.cleanup() }
        await model.start()
        #expect(model.isPaired)
        #expect(model.pairingCode == key.code)
        await model.unpair()
        #expect(!model.isPaired)
        #expect(model.pairingCode == nil)
        #expect(store.load() == nil)
    }
}

#if os(macOS)
@MainActor
@Suite(.serialized) struct WatchedFoldersTests {
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(80)) }
        return condition()
    }

    @Test func songsAlreadyInTheFolderAndSongsAddedLaterAreImportedAutomatically() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let folder = app.dir.appendingPathComponent("Telegram Desktop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeWAV(at: folder.appendingPathComponent("Before.wav"), seed: 1)

        await app.model.watched.add(folder)
        #expect(await eventually { app.model.library.tracks.count == 1 })      // catches up on what was already there

        try makeWAV(at: folder.appendingPathComponent("After.wav"), seed: 2)
        #expect(await eventually { app.model.library.tracks.count == 2 })      // and sees new files arrive
        #expect(app.model.watched.entries.map(\.path) == [folder.path])
        #expect(app.model.watched.entries.allSatisfy { $0.isAvailable })
    }

    @Test func stoppingWatchingStopsImporting() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let folder = app.dir.appendingPathComponent("Music Drop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await app.model.watched.add(folder)
        try makeWAV(at: folder.appendingPathComponent("One.wav"), seed: 3)
        #expect(await eventually { app.model.library.tracks.count == 1 })

        await app.model.watched.remove(path: folder.path)
        #expect(app.model.watched.entries.isEmpty)
        try makeWAV(at: folder.appendingPathComponent("Two.wav"), seed: 4)
        try await Task.sleep(for: .seconds(3))
        #expect(app.model.library.tracks.count == 1)
    }
}
#endif
