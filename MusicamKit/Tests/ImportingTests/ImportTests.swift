import Testing
import Foundation
import Domain
import Persistence
@testable import Importing

@Suite struct ScannerTests {
    @Test func expandsFoldersRecursivelyAndKeepsOnlyAudio() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try makeWAV(at: dir.appendingPathComponent("a.wav"))
        try Data([1]).write(to: dir.appendingPathComponent("sub/b.mp3"))
        try Data([1]).write(to: dir.appendingPathComponent("notes.txt"))
        try Data([1]).write(to: dir.appendingPathComponent("cover.jpg"))
        try Data([1]).write(to: dir.appendingPathComponent(".hidden.wav"))
        try Data([1]).write(to: dir.appendingPathComponent("c.ogg"))

        let names = AudioFileScanner.audioFiles(in: [dir]).map(\.lastPathComponent)
        #expect(names == ["a.wav", "c.ogg", "b.mp3"])
    }

    @Test func aSingleFileAndAMissingPathAreHandled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("x.wav")
        try makeWAV(at: wav)
        let found = AudioFileScanner.audioFiles(in: [wav, dir.appendingPathComponent("nope.wav")])
        #expect(found == [wav])
    }
}

@Suite struct ImportServiceTests {
    @Test func importsFilesWithTitleFromFilenameAndFormatFromTheFile() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let folder = h.dir.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 1...3 { try makeWAV(at: folder.appendingPathComponent("Song \(i).wav"), seed: i) }

        let summary = await h.importAll([folder])
        #expect(summary.imported == 3)
        #expect(summary.failed == 0)

        let tracks = try await h.library.allTracks()
        #expect(Set(tracks.map(\.title)) == ["Song 1", "Song 2", "Song 3"])
        let t = try #require(tracks.first)
        #expect(t.file?.format.codec == "WAV")
        #expect(t.file?.format.sampleRate == 8000)
        #expect(t.file?.format.bitDepth == 16)
        #expect(t.file?.format.isLossless == true)
        #expect(abs(t.duration - 0.2) < 0.05)
    }

    @Test func importedFilesCanBeOpenedLaterThroughTheirBookmarks() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let wav = h.dir.appendingPathComponent("Keep.wav")
        try makeWAV(at: wav)
        _ = await h.importAll([wav])

        let fileID = try #require(try await h.library.allTracks().first?.file?.id)
        let access = try await FileAccessService(device: h.device).open(fileID)
        #expect(access.url.lastPathComponent == "Keep.wav")
    }

    @Test func runningTheSameImportAgainChangesNothing() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        for i in 1...3 { try makeWAV(at: h.dir.appendingPathComponent("s\(i).wav"), seed: i) }
        _ = await h.importAll([h.dir])
        let second = await h.importAll([h.dir])
        #expect(second.unchanged == 3)
        #expect(second.imported == 0)
        #expect(try await h.library.trackCount() == 3)
    }

    @Test func aCopyUnderAnotherNameIsADuplicateNotANewTrack() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let a = h.dir.appendingPathComponent("original.wav")
        try makeWAV(at: a, seed: 5)
        try FileManager.default.copyItem(at: a, to: h.dir.appendingPathComponent("copy of original.wav"))
        let summary = await h.importAll([h.dir])
        #expect(summary.imported == 1)
        #expect(summary.duplicates == 1)
        #expect(try await h.library.trackCount() == 1)
    }

    @Test func unsupportedAndBrokenFilesAreCountedNotSilentlyDropped() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try Data(repeating: 1, count: 100).write(to: h.dir.appendingPathComponent("a.ogg"))
        try Data(repeating: 2, count: 100).write(to: h.dir.appendingPathComponent("broken.mp3"))
        try makeWAV(at: h.dir.appendingPathComponent("fine.wav"))
        let summary = await h.importAll([h.dir])
        #expect(summary.unsupported == 1)
        #expect(summary.failed == 1)
        #expect(summary.imported == 1)
    }

    @Test func progressEventsReportEveryFile() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        for i in 1...4 { try makeWAV(at: h.dir.appendingPathComponent("p\(i).wav"), seed: i) }
        var total = 0, lastDone = 0
        for await event in h.service.run([h.dir]) {
            switch event {
            case .discovered(let n): total = n
            case .progress(let done, _, _): lastDone = done
            case .finished: break
            }
        }
        #expect(total == 4)
        #expect(lastDone == 4)
    }
}

@Suite struct TagReadingTests {
    @Test func readsID3TagsFromAnMP3IncludingPersianText() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let mp3 = h.dir.appendingPathComponent("raw_file_name.mp3")
        try makeMP3(at: mp3, title: "نیمه‌شب", artist: "گروه نمونه", album: "شب‌نامه", track: "3/12", year: "2019", genre: "(17)Rock")
        let raw = try await AVFoundationTagReader().read(mp3)
        let m = raw.metadata
        #expect(m.title == "نیمه‌شب")
        #expect(m.artist == "گروه نمونه")
        #expect(m.album == "شب‌نامه")
        #expect(m.trackNumber == 3)
        #expect(m.year == 2019)
        #expect(m.genre == "Rock")
        #expect(m.format.codec == "MP3")
        #expect(m.format.isLossless == false)
        #expect(abs(Double(m.format.bitrate ?? 0) - 128_000) < 8_000)
        #expect(m.duration > 0.8 && m.duration < 1.4)
    }

    @Test func readsM4ATagsAndExtractsCoverArt() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let wav = h.dir.appendingPathComponent("src.wav")
        try makeWAV(at: wav, seconds: 1)
        let m4a = h.dir.appendingPathComponent("tagged.m4a")
        try await makeTaggedM4A(at: m4a, from: wav, title: "Slow Tide", artist: "The Quiet Hours", album: "Saffron Skies",
                                year: "2021", genre: "Ambient", artwork: try makePNG())
        let summary = await h.importAll([m4a])
        #expect(summary.imported == 1)

        let t = try #require(try await h.library.allTracks().first)
        #expect(t.title == "Slow Tide")
        #expect(t.artist == "The Quiet Hours")
        #expect(t.album == "Saffron Skies")
        #expect(t.year == 2021)
        #expect(t.genre == "Ambient")
        #expect(t.file?.format.codec == "AAC")
        let key = try #require(t.artworkKey)
        #expect(h.artwork.data(for: key) != nil)
    }

    @Test func yearAndGenreParsingEdgeCases() {
        #expect(AVFoundationTagReader.year(from: "2021-05-01") == 2021)
        #expect(AVFoundationTagReader.year(from: "abc") == nil)
        #expect(AVFoundationTagReader.year(from: nil) == nil)
        #expect(AVFoundationTagReader.cleanGenre("(17)Rock") == "Rock")
        #expect(AVFoundationTagReader.cleanGenre("(17)") == "")
        #expect(AVFoundationTagReader.cleanGenre("Jazz") == "Jazz")
    }
}

@Suite struct LargeLibraryTests {
    @Test func importsTwoThousandFilesAndReportsTheTime() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let folder = h.dir.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<2000 { try makeWAV(at: folder.appendingPathComponent(String(format: "track %04d.wav", i)), seconds: 0.2, seed: i) }

        let summary = await h.importAll([folder])
        print("PERF import 2000 files: \(String(format: "%.2f", summary.elapsed)) s, \(summary)")
        #expect(summary.imported == 2000)
        #expect(summary.failed == 0)
        #expect(try await h.library.trackCount() == 2000)
        #expect(summary.elapsed < 120)

        // loading the whole library for the UI must also be quick
        let t0 = Date()
        let all = try await h.library.allTracks()
        print("PERF allTracks(2000): \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
        #expect(all.count == 2000)
    }
}

#if os(macOS)
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct FolderWatcherTests {
    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    @Test func aNewFileInTheFolderTriggersOneGroupedCallback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = Counter()
        let watcher = FolderWatcher(folder: dir, debounce: 0.4) { hits.bump() }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        for i in 1...3 { try makeWAV(at: dir.appendingPathComponent("a\(i).wav"), seed: i) }   // a burst of three files
        #expect(await waitFor(6) { hits.value >= 1 })
        try await Task.sleep(for: .seconds(1))
        #expect(hits.value <= 2)          // grouped, not one callback per file
    }

    @Test func changesInsideSubfoldersAreSeenAndStoppingSilencesTheWatcher() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Telegram Audio"), withIntermediateDirectories: true)
        let hits = Counter()
        let watcher = FolderWatcher(folder: dir, debounce: 0.3) { hits.bump() }
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        try makeWAV(at: dir.appendingPathComponent("Telegram Audio/song.wav"), seed: 5)
        #expect(await waitFor(6) { hits.value >= 1 })

        watcher.stop()
        let before = hits.value
        try makeWAV(at: dir.appendingPathComponent("later.wav"), seed: 6)
        try await Task.sleep(for: .seconds(1.5))
        #expect(hits.value == before)
    }
}
#endif
