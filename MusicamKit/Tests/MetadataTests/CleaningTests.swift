import Testing
import Foundation
import Domain
@testable import Metadata

@Suite struct CleaningTests {
    @Test func cleansDownloadStyleFilename() {
        let r = FilenameCleaner.clean(filename: "07_Zedbazi_-_Bache_Mahal_[320]_[www.site.com].mp3")
        #expect(r.artist == "Zedbazi")
        #expect(r.title == "Bache Mahal")
    }

    @Test func keepsMeaningfulBrackets() {
        let r = FilenameCleaner.clean(filename: "Artist - Song (Live in Tehran).mp3")
        #expect(r.title == "Song (Live in Tehran)")
    }

    @Test func stripsOfficialAudioAndTrackNumber() {
        let r = FilenameCleaner.clean(filename: "03. Artist - Name (Official Audio).m4a")
        #expect(r.artist == "Artist")
        #expect(r.title == "Name")
    }

    @Test func noSeparatorGivesTitleOnly() {
        let r = FilenameCleaner.clean(filename: "OnlyTitle.mp3")
        #expect(r.artist == nil)
        #expect(r.title == "OnlyTitle")
    }

    @Test func genericTitles() {
        #expect(FilenameCleaner.isGeneric("Track 07"))
        #expect(FilenameCleaner.isGeneric("12"))
        #expect(!FilenameCleaner.isGeneric("Bache Mahal"))
    }

    @Test func repairsWindows1256Persian() {
        // "سلام" as Windows-1256 bytes read as Windows-1252 text
        let bytes: [UInt8] = [0xD3, 0xE1, 0xC7, 0xE3]
        let text = String(data: Data(bytes), encoding: .windowsCP1252)!
        #expect(MojibakeRepair.repaired(text) == "سلام")
    }

    @Test func repairsUTF8ReadAsLatin() {
        let text = String(data: "Café".data(using: .utf8)!, encoding: .windowsCP1252)!
        #expect(text != "Café")
        #expect(MojibakeRepair.repaired(text) == "Café")
    }

    @Test func leavesGoodTextAlone() {
        #expect(MojibakeRepair.repaired("Hello") == nil)
        #expect(MojibakeRepair.repaired("سلام") == nil)
        #expect(MojibakeRepair.repaired("Café") == nil)
    }

    @Test func persianLetterNormalization() {
        #expect(PersianNormalizer.normalize("كتاب يك") == "کتاب یک")
    }
}
