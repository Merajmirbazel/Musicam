import Testing
import Foundation
import Domain
@testable import Metadata

@Suite struct PlannerTests {
    private func file(_ name: String) -> AudioFileInfo {
        AudioFileInfo(contentHash: UUID().uuidString, byteSize: 1, originalFilename: name,
                      format: AudioFormat(codec: "MP3", sampleRate: 44100, channels: 2, bitrate: 128_000), duration: 200)
    }

    @Test func fixesGarbledAndJunk() {
        let garbled = String(data: Data([0xD3, 0xE1, 0xC7, 0xE3]), encoding: .windowsCP1252)!
        let t = Track(title: garbled, artist: "Zedbazi [www.site.com]", file: file("a.mp3"))
        let p = RepairPlanner.proposal(for: t)
        #expect(p?.edit.title == "سلام")
        #expect(p?.edit.artist == "Zedbazi")
        #expect(p?.isSafe == true)
    }

    @Test func takesNamesFromFilenameWithLowerConfidence() {
        let t = Track(title: "Track 07", file: file("Zedbazi - Bache Mahal.mp3"))
        let p = RepairPlanner.proposal(for: t)
        #expect(p?.edit.title == "Bache Mahal")
        #expect(p?.edit.artist == "Zedbazi")
        #expect(p?.isSafe == false)
    }

    @Test func untaggedDownloadTitleBecomesArtistAndTitleFromFilename() {
        let name = "07_Kian_-_Night_Walk_[128]_[www.music-site.ir].mp3"
        let t = Track(title: (name as NSString).deletingPathExtension, file: file(name))
        let p = RepairPlanner.proposal(for: t)
        #expect(p?.edit.title == "Night Walk")
        #expect(p?.edit.artist == "Kian")
    }

    @Test func cleanTrackNeedsNothing() {
        let t = Track(title: "Song", artist: "Artist", album: "Album", file: file("x.mp3"))
        #expect(RepairPlanner.proposal(for: t) == nil)
    }

    @Test func undoEditRestoresBefore() {
        let t = Track(title: "Song [320]", artist: "Artist")
        let p = RepairPlanner.proposal(for: t)!
        #expect(p.edit.title == "Song")
        #expect(p.undoEdit.title == "Song [320]")
    }

    @Test func historyPersistsAndMarksUndone() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let h = RepairHistory(url: url)
        let p = RepairPlanner.proposal(for: Track(title: "A (Official Audio)"))!
        let r = await h.record(p)
        await h.markUndone(r.id)
        let reopened = RepairHistory(url: url)
        let all = await reopened.all()
        #expect(all.count == 1)
        #expect(all[0].undoneAt != nil)
        #expect(all[0].undoEdit.title == "A (Official Audio)")
    }

    @Test func findsDuplicatesAndPrefersLossless() {
        let lossless = AudioFileInfo(contentHash: "h1", byteSize: 1, originalFilename: "a.flac",
                                     format: AudioFormat(codec: "FLAC", sampleRate: 44100, bitDepth: 16, channels: 2, isLossless: true), duration: 200)
        let a = Track(title: "Café Blue!", artist: "X", duration: 200, file: lossless)
        let b = Track(title: "cafe blue", artist: "x", duration: 201, file: file("b.mp3"))
        let c = Track(title: "Other", artist: "X", duration: 200, file: file("c.mp3"))
        let groups = TagSanity.duplicateGroups(in: [b, c, a])
        #expect(groups.count == 1)
        #expect(groups[0].first?.id == a.id)
    }

    @Test func detectsIssues() {
        let t = Track(title: "Track 03", artist: "", file: file("Track 03.mp3"))
        let issues = TagSanity.issues(for: t)
        #expect(issues.contains(.missingArtist))
        #expect(issues.contains(.genericTitle))
        #expect(issues.contains(.noArtwork))
    }

    @Test func plausibleYearIsGregorianEvenWhenTheDeviceUsesAnotherCalendar() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)          // 2027
        #expect(TagSanity.maxPlausibleYear(now: date) == 2028)
        let t = Track(title: "x", year: 2010)
        #expect(!TagSanity.issues(for: t).contains(.suspiciousYear))
        #expect(TagSanity.issues(for: Track(title: "x", year: 1405)).contains(.suspiciousYear))   // a Persian-calendar year typed by mistake
    }
}
