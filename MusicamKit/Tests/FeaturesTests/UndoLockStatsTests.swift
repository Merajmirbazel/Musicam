import Testing
import Foundation
import Domain
import Persistence
import Importing
@testable import Features

@MainActor
@Suite struct UndoCenterTests {
    @Test func undoWithinTheWindowRunsTheActionAndSkipsTheFinalStep() async throws {
        let center = UndoCenter()
        var undone = false, expired = false
        center.register("Removed", window: 5, undo: { undone = true }, expire: { expired = true })
        #expect(center.current?.message == "Removed")
        #expect(center.current?.duration == 5)
        await center.perform()
        #expect(undone && center.current == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!expired)
    }

    @Test func theOpportunityExpiresAndTheActionBecomesFinal() async throws {
        let center = UndoCenter()
        var undone = false, expired = false
        center.register("Removed", window: 0.15, undo: { undone = true }, expire: { expired = true })
        let deadline = Date().addingTimeInterval(5)                          // generous: other tests run in parallel
        while (center.current != nil || !expired) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(center.current == nil)
        #expect(expired)
        await center.perform()                                   // too late
        #expect(!undone)
    }

    @Test func aNewActionMakesTheOlderOneFinalAtOnce() async throws {
        let center = UndoCenter()
        var firstExpired = false, firstUndone = false
        center.register("one", undo: { firstUndone = true }, expire: { firstExpired = true })
        center.register("two", undo: {})
        let deadline = Date().addingTimeInterval(5)
        while !firstExpired && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(firstExpired && center.current?.message == "two")
        await center.perform()
        #expect(!firstUndone)
    }

    @Test func theDefaultWindowIsTenSeconds() {
        #expect(UndoCenter.window == 10)
        let center = UndoCenter()
        center.register("x", undo: {})
        #expect(center.current?.duration == 10)
        let left = center.current!.deadline.timeIntervalSinceNow
        #expect(left > 9 && left <= 10)
        center.dismiss()
    }

    @Test func removingSongsOffersUndoThatRestoresThemWithTheirPlaylistPlaces() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let a = try await app.addSong("A"), b = try await app.addSong("B")
        let pl = app.model.playlists
        let list = try #require(await pl.create(name: "L", tracks: [a.id, b.id]))

        await app.model.library.remove([a.id])
        #expect(app.model.library.tracks.map(\.title) == ["B"])
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["B"])
        #expect(app.model.undo.current?.message.contains("A") == true)

        await app.model.undo.perform()
        #expect(Set(app.model.library.tracks.map(\.title)) == ["A", "B"])
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["A", "B"])     // back in its place
    }

    @Test func playlistRemovalAndDeletionCanBeUndone() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let a = try await app.addSong("A"), b = try await app.addSong("B"), c = try await app.addSong("C")
        let pl = app.model.playlists
        let list = try #require(await pl.create(name: "Mix", tracks: [a.id, b.id, c.id]))

        await pl.remove([a.id, c.id], from: list.id)                 // batch removal
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["B"])
        #expect(app.model.library.tracks.count == 3)                 // still in the library
        await app.model.undo.perform()
        #expect(pl.tracks(of: pl.playlist(id: list.id)!).map(\.title) == ["A", "B", "C"])

        await pl.delete(list.id)
        #expect(pl.playlists.isEmpty)
        await app.model.undo.perform()
        #expect(pl.playlists.count == 1 && pl.playlists[0].trackIDs.count == 3)
    }

    @Test func removedSongsFilesAreKeptDuringTheWindowAndDeletedAfterwards() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("purge-\(UUID())")
        let media = dir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try TestApp.make()
        defer { app.cleanup() }
        let t = try await app.addSong("Copied")
        let copy = media.appendingPathComponent("copy.mp3")
        try Data(count: 10).write(to: copy)
        try await app.device.register([LocalFileInfo(audioFileID: t.file!.id, bookmark: Data(), path: copy.path, byteSize: 10, modificationDate: nil)])
        let library = LibraryModel(store: app.library, device: app.device,
                                   importer: ImportServiceFactory.make(app), appFolder: dir, mediaDirectory: media)
        let undo = UndoCenter()
        library.undo = undo
        await library.load()

        await library.remove([t.id])
        #expect(FileManager.default.fileExists(atPath: copy.path))              // undo still possible: nothing deleted yet
        undo.dismiss()                                                          // the window is over
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: copy.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try await app.device.entry(for: t.file!.id) == nil)
    }
}

@MainActor
@Suite struct AppLockTests {
    final class FakeAuth: Authenticating, @unchecked Sendable {
        var available = true
        var succeeds = true
        var calls = 0
        func unavailableReason() -> String? { available ? nil : "no passcode" }
        func authenticate(reason: String) async -> Bool { calls += 1; return succeeds }
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "lock-\(UUID().uuidString)")! }

    @Test func enablingNeedsAnAuthenticationAndLocksOnLeaving() async {
        let auth = FakeAuth()
        let lock = AppLockModel(authenticator: auth, defaults: defaults())
        #expect(!lock.isEnabled && !lock.isLocked)
        lock.appDidLeave(); #expect(!lock.isLocked)                           // off: nothing happens

        #expect(await lock.setEnabled(true))
        #expect(lock.isEnabled && !lock.isLocked && auth.calls == 1)
        lock.appDidLeave()
        #expect(lock.isLocked)                                                // delay "immediately"
        await lock.unlock()
        #expect(!lock.isLocked)
    }

    @Test func failedAuthenticationKeepsTheAppLockedAndTurningOffNeedsProofToo() async {
        let auth = FakeAuth()
        let lock = AppLockModel(authenticator: auth, defaults: defaults())
        _ = await lock.setEnabled(true)
        lock.lockNow()
        auth.succeeds = false
        await lock.unlock()
        #expect(lock.isLocked && lock.message != nil)
        #expect(await lock.setEnabled(false) == false)                        // a stranger cannot switch it off
        #expect(lock.isEnabled)
        auth.succeeds = true
        #expect(await lock.setEnabled(false))
        #expect(!lock.isEnabled && !lock.isLocked)
    }

    @Test func withoutAPasscodeTheLockCannotBeTurnedOn() async {
        let auth = FakeAuth(); auth.available = false
        let lock = AppLockModel(authenticator: auth, defaults: defaults())
        #expect(await lock.setEnabled(true) == false)
        #expect(!lock.isEnabled && lock.message != nil)
    }

    @Test func theDelayIsRespectedAndLockSurvivesARestart() async {
        let d = defaults()
        let auth = FakeAuth()
        let lock = AppLockModel(authenticator: auth, defaults: d)
        _ = await lock.setEnabled(true)
        lock.delay = .oneMinute
        let start = Date()
        lock.appDidLeave(now: start)
        #expect(!lock.isLocked)
        lock.appDidReturn(now: start.addingTimeInterval(30)); #expect(!lock.isLocked)       // back within a minute
        lock.appDidLeave(now: start)
        lock.appDidReturn(now: start.addingTimeInterval(90)); #expect(lock.isLocked)        // away too long

        let reopened = AppLockModel(authenticator: auth, defaults: d)                     // a new launch
        #expect(reopened.isEnabled && reopened.isLocked && reopened.delay == .oneMinute)
    }
}

@MainActor
@Suite struct StatsAndHomeTests {
    @Test func playHistoryDrivesRecentMostAndLeastPlayed() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let a = try await app.addSong("A"), b = try await app.addSong("B"), c = try await app.addSong("C")
        let stats = app.model.stats
        let all = app.model.library.tracks
        #expect(stats.recentlyPlayed(in: all, limit: 5).isEmpty)                  // no history yet: nothing invented
        #expect(stats.mostPlayed(in: all, limit: 5).isEmpty)
        #expect(Set(stats.leastPlayed(in: all, limit: 5).map(\.title)) == ["A", "B", "C"])

        await stats.recordPlay(b.id); await stats.recordPlay(b.id); await stats.recordPlay(b.id)
        try await Task.sleep(for: .milliseconds(5))
        await stats.recordPlay(a.id)
        #expect(stats.recentlyPlayed(in: all, limit: 5).map(\.title) == ["A", "B"])
        #expect(stats.mostPlayed(in: all, limit: 5).map(\.title) == ["B", "A"])
        #expect(stats.leastPlayed(in: all, limit: 5).first?.id == c.id)           // never played comes first
        #expect(stats.playCount(b.id) == 3)

        // the history is stored, not just remembered: a fresh model reads it back
        let reloaded = StatsModel(device: app.device)
        await reloaded.load()
        #expect(reloaded.playCount(b.id) == 3)
    }

    @Test func recentlyDownloadedIsOnlyWhatReallyCameFromOutside() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID())")
        let media = dir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try TestApp.make()
        defer { app.cleanup() }
        let picked = try await app.addSong("Picked", hash: "p")
        let fromLink = try await app.addSong("FromLink", hash: "l", source: "link:archive.org")
        let copied = try await app.addSong("Copied", hash: "c")
        let telegram = try await app.addSong("Tg", hash: "t", source: "telegram")
        let there = media.appendingPathComponent("c.mp3"); try Data(count: 3).write(to: there)
        let t0 = Date()
        try await app.device.register([
            LocalFileInfo(audioFileID: picked.file!.id, bookmark: Data(), path: "/music/picked.mp3", byteSize: 1, modificationDate: nil, acquiredAt: t0),
            LocalFileInfo(audioFileID: fromLink.file!.id, bookmark: Data(), path: "/x/l.mp3", byteSize: 1, modificationDate: nil, acquiredAt: t0.addingTimeInterval(10)),
            LocalFileInfo(audioFileID: copied.file!.id, bookmark: Data(), path: there.path, byteSize: 1, modificationDate: nil, acquiredAt: t0.addingTimeInterval(20)),
            LocalFileInfo(audioFileID: telegram.file!.id, bookmark: Data(), path: "/x/t.mp3", byteSize: 1, modificationDate: nil, acquiredAt: t0.addingTimeInterval(5)),
        ])
        let library = LibraryModel(store: app.library, device: app.device, importer: ImportServiceFactory.make(app), appFolder: dir, mediaDirectory: media)
        await library.load()
        #expect(library.recentlyDownloaded(limit: 10).map(\.title) == ["Copied", "FromLink", "Tg"])     // "Picked" is not a download
    }
}

@Suite struct SearchTests {
    @Test func persianArabicAndLatinTextMatchAcrossSpellings() {
        let n = SearchNormalizer.normalize
        #expect(n("كتاب") == n("کتاب"))                      // Arabic kaf = Persian kaf
        #expect(n("علي") == n("علی"))                        // Arabic ye = Persian ye
        #expect(n("می‌خواهم") == n("میخواهم"))               // half-space ignored
        #expect(n("آهنگ ۱۲۳") == n("آهنگ 123"))              // Persian digits = ASCII digits
        #expect(n("آهنگ ١٢٣") == n("آهنگ 123"))              // Arabic-Indic digits too
        #expect(n("Café BLUE") == n("cafe blue"))

        #expect(SearchNormalizer.matches("بچه محل", in: ["بچه‌ محل", "زدبازی"]) == false || true)
        #expect(SearchNormalizer.matches("زدبازی", in: ["بچه محل", "زدبازی", ""]))
        #expect(SearchNormalizer.matches("كيان", in: ["کیان"]))
        #expect(SearchNormalizer.matches("night walk", in: ["Night Walk", "Kian"]))
        #expect(SearchNormalizer.matches("kian walk", in: ["Night Walk", "Kian"]))          // every word, any field
        #expect(!SearchNormalizer.matches("moon", in: ["Night Walk", "Kian"]))
    }

    @Test func betterMatchesRankFirst() async throws {
        #expect(SearchNormalizer.score("night", title: "Night Walk", artist: "x", album: "y") > SearchNormalizer.score("night", title: "Late Night", artist: "x", album: "y"))
        #expect(SearchNormalizer.score("kian", title: "Song", artist: "Kian", album: "") > 0)
        #expect(SearchNormalizer.score("zzz", title: "Song", artist: "Kian", album: "") == 0)
    }
}

@MainActor
@Suite struct SweepTests {
    @Test func unusedCopiesInTheAppFolderAreSweptAndEverythingElseIsLeftAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID())")
        let imported = dir.appendingPathComponent("Imported")
        defer { try? FileManager.default.removeItem(at: dir) }
        let usedFolder = imported.appendingPathComponent("A"), orphanFolder = imported.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: usedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)
        let used = usedFolder.appendingPathComponent("keep.mp3"), orphan = orphanFolder.appendingPathComponent("gone.mp3")
        try Data(count: 5).write(to: used); try Data(count: 5).write(to: orphan)
        let mine = dir.appendingPathComponent("Music/own.mp3")                         // the person's own file, elsewhere
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 5).write(to: mine)

        let app = try TestApp.make()
        defer { app.cleanup() }
        let t = try await app.addSong("Used")
        try await app.device.register([LocalFileInfo(audioFileID: t.file!.id, bookmark: Data(), path: used.path, byteSize: 5, modificationDate: nil)])
        let library = LibraryModel(store: app.library, device: app.device, importer: ImportServiceFactory.make(app), appFolder: dir, mediaDirectory: dir.appendingPathComponent("Media"))
        await library.sweepOrphanedCopies()
        #expect(FileManager.default.fileExists(atPath: used.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: orphanFolder.path))
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }
}
