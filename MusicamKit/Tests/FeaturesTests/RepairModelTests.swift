import Testing
import Foundation
import Domain
import Metadata
@testable import Features

@MainActor
@Suite struct RepairModelTests {
    private struct FakeLookup: RecordingLookup {
        func search(title: String, artist: String?) async throws -> [MusicBrainzMatch] {
            [MusicBrainzMatch(recordingID: "r", title: title, artist: "Found Artist", album: "Found Album", releaseID: nil, year: 2001, score: 100)]
        }
    }

    @Test func appliesSafeRepairsAndUndoesThem() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let t = try await app.addSong("Night Drive [320] [www.site.com]", artist: "Nova")
        let repair = RepairModel(library: app.model.library, historyURL: nil)
        await repair.scan()
        #expect(repair.proposals.count == 1)
        #expect(repair.safeProposals.count == 1)

        await repair.applySafe()
        #expect(app.model.library.track(id: t.id)?.title == "Night Drive")
        #expect(repair.proposals.isEmpty)
        #expect(repair.history.count == 1)

        await repair.undo(repair.history[0])
        #expect(app.model.library.track(id: t.id)?.title == "Night Drive [320] [www.site.com]")
        #expect(repair.history[0].undoneAt != nil)
    }

    @Test func skippedSuggestionDoesNotComeBack() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let t = try await app.addSong("Song (Official Audio)")
        let repair = RepairModel(library: app.model.library, historyURL: nil)
        await repair.scan()
        await repair.skip(t.id)
        #expect(repair.proposals.isEmpty)
        await repair.scan()
        #expect(repair.proposals.isEmpty)
    }

    @Test func onlineLookupAddsSuggestionsForSongsWithMissingDetails() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        let t = try await app.addSong("Lonely Song", artist: "", album: "")
        let repair = RepairModel(library: app.model.library, historyURL: nil, lookup: FakeLookup())
        await repair.lookUpOnline()
        #expect(repair.proposals.first?.edit.artist == "Found Artist")
        await repair.apply([t.id])
        #expect(app.model.library.track(id: t.id)?.artist == "Found Artist")
        #expect(app.model.library.track(id: t.id)?.album == "Found Album")
    }

    @Test func duplicateCleanupKeepsTheBestCopy() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        try await app.addSong("Same Song", artist: "Same", hash: "h1")
        try await app.addSong("same song", artist: "same", hash: "h2")
        let repair = RepairModel(library: app.model.library, historyURL: nil)
        await repair.scan()
        #expect(repair.duplicates.count == 1)
        await repair.removeDuplicates(inGroup: repair.duplicates[0])
        #expect(app.model.library.tracks.count == 1)
    }

    @Test func coverIsFetchedAppliedAndUndone() async throws {
        struct WithRelease: RecordingLookup {
            func search(title: String, artist: String?) async throws -> [MusicBrainzMatch] {
                [MusicBrainzMatch(recordingID: "r", title: title, artist: artist ?? "A", album: "Alb", releaseID: "rel", year: nil, score: 100)]
            }
        }
        let app = try TestApp.make()
        defer { app.cleanup() }
        let t = try await app.addSong("Covered Song", artist: "A", album: "Alb")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let repair = RepairModel(library: app.model.library, historyURL: nil, lookup: WithRelease(),
                                 artworkStore: app.artwork, cover: { _ in png })
        await repair.lookUpOnline()
        #expect(repair.proposals.first?.changes.first?.field == .artwork)
        await repair.apply([t.id])
        let key = try #require(app.model.library.track(id: t.id)?.artworkKey)
        #expect(app.artwork.data(for: key) != nil)
        await repair.undo(repair.history[0])
        #expect(app.model.library.track(id: t.id)?.artworkKey == nil)
    }

    @Test func appliedRepairsAreForgottenWhenTheUndoTimeIsOver() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        _ = try await app.addSong("Night Drive [320] [www.site.com]", artist: "Nova")
        let undo = UndoCenter()
        let repair = RepairModel(library: app.model.library, historyURL: nil)
        repair.undoCenter = undo
        await repair.scan()
        await repair.applySafe()
        #expect(repair.history.count == 1)
        undo.dismiss()                       // same as the ten seconds running out
        let deadline = Date().addingTimeInterval(5)
        while !repair.history.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(repair.history.isEmpty)
    }

    @Test func songsWithoutDetailsAreListedForWebSearch() async throws {
        let app = try TestApp.make()
        defer { app.cleanup() }
        _ = try await app.addSong("Lonely Song", artist: "", album: "")
        let repair = RepairModel(library: app.model.library, historyURL: nil)
        await repair.scan()
        #expect(repair.missingDetails.map(\.title) == ["Lonely Song"])
    }

    @Test func onlineSearchModelRemembersWhatWasAdded() async throws {
        let online = OnlineSearchModel(download: { _ in .imported("x.mp3") })
        let file = ArchiveFile(name: "a.mp3", size: 1, url: URL(string: "https://archive.org/download/a/a.mp3")!)
        await online.get(file)
        #expect(online.added.contains(file.id))
        let failing = OnlineSearchModel(download: { _ in .failed("nope") })
        await failing.get(file)
        #expect(failing.message == "nope")
        #expect(failing.added.isEmpty)
    }
}
