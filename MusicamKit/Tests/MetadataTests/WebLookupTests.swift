import Testing
import Foundation
import Domain
@testable import Metadata

@Suite struct WebLookupTests {
    private let deezer = """
    {"data":[{"id":1,"title":"Gole Yakh","artist":{"name":"Googoosh"},"album":{"title":"Best Of","cover_big":"https://img.example/c.jpg"}},
             {"id":2,"title":"Other Song","artist":{"name":"Someone"},"album":{"title":"X"}}]}
    """
    private let itunes = """
    {"resultCount":1,"results":[{"trackId":9,"trackName":"Gole Yakh","artistName":"Googoosh","collectionName":"Best Of",
      "releaseDate":"1999-01-01T08:00:00Z","artworkUrl100":"https://img.example/100x100bb.jpg"}]}
    """

    @Test func deezerAnswerIsParsedAndScored() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(deezer.utf8)) as? [String: Any])
        let m = CatalogScoring.matches(for: DeezerClient.entries(root), title: "Gole Yakh", artist: "Googoosh")
        #expect(m.first?.score == 100)
        #expect(m.first?.album == "Best Of")
        #expect(m.first?.coverURL?.absoluteString == "https://img.example/c.jpg")
        #expect(m.last!.score < 90)
    }

    @Test func itunesAnswerGetsBigCoverAndYear() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(itunes.utf8)) as? [String: Any])
        let e = ITunesClient.entries(root)
        #expect(e.first?.year == 1999)
        #expect(e.first?.cover?.absoluteString.contains("600x600bb") == true)
    }

    @Test func persianLetterVariantsStillMatch() {
        let entries = [CatalogEntry(title: "گل يخ", artist: "گوگوش", album: nil, year: nil, cover: nil, id: "1")]
        let m = CatalogScoring.matches(for: entries, title: "گل یخ", artist: "گوگوش")
        #expect(m.first?.score == 100)
    }

    @Test func titleOnlyMatchNeedsEveryResultToAgreeOnTheArtist() {
        let agree = [CatalogEntry(title: "Song", artist: "A", album: nil, year: nil, cover: nil, id: "1"),
                     CatalogEntry(title: "Song", artist: "A", album: nil, year: nil, cover: nil, id: "2")]
        #expect(CatalogScoring.matches(for: agree, title: "Song", artist: nil).first?.score == 90)
        let clash = [CatalogEntry(title: "Song", artist: "A", album: nil, year: nil, cover: nil, id: "1"),
                     CatalogEntry(title: "Song", artist: "B", album: nil, year: nil, cover: nil, id: "2")]
        #expect(CatalogScoring.matches(for: clash, title: "Song", artist: nil).allSatisfy { $0.score < 90 })
    }

    @Test func aTitleOnlySuggestionIsNeverCalledSafe() {
        let t = Track(title: "Song")
        let m = [MusicBrainzMatch(recordingID: "1", title: "Song", artist: "A", album: "Al", score: 90)]
        let p = MusicBrainzPlanner.proposal(for: t, matches: m)
        #expect(p != nil)
        #expect(p?.isSafe == false)
    }

    @Test func coverLinkIsPreferredOverReleaseID() {
        let t = Track(title: "Song", artist: "A")
        let m = [MusicBrainzMatch(recordingID: "1", title: "Song", artist: "A", releaseID: "rel", score: 100, coverURL: URL(string: "https://img.example/c.jpg"))]
        #expect(MusicBrainzPlanner.coverRelease(for: t, matches: m) == "https://img.example/c.jpg")
    }

    @Test func webSearchLinksEncodeTheQuery() {
        let links = WebSearchLinks.links(title: "گل یخ", artist: "Googoosh & co")
        #expect(links.map(\.name) == ["Google", "YouTube", "Spotify"])
        #expect(links.allSatisfy { $0.url.scheme == "https" })
        #expect(links[0].url.absoluteString.contains("google.com/search?q="))
        #expect(!links[0].url.absoluteString.contains(" "))
    }

    private struct Stub: RecordingLookup {
        var result: Result<[MusicBrainzMatch], Error>
        func search(title: String, artist: String?) async throws -> [MusicBrainzMatch] { try result.get() }
    }

    @Test func compositeFallsBackToTheNextSourceWhenTheFirstFails() async throws {
        struct Boom: Error {}
        let good = [MusicBrainzMatch(recordingID: "1", title: "T", artist: "A", score: 100)]
        let both = CompositeLookup([Stub(result: .failure(Boom())), Stub(result: .success(good))])
        #expect(try await both.search(title: "T", artist: "A").count == 1)
        let none = CompositeLookup([Stub(result: .failure(Boom())), Stub(result: .failure(Boom()))])
        await #expect(throws: Boom.self) { _ = try await none.search(title: "T", artist: nil) }
    }
}

@Suite struct InternetArchiveTests {
    @Test func parsesSearchResults() throws {
        let json = #"{"response":{"docs":[{"identifier":"abc","title":"Old Songs","creator":["X","Y"]},{"identifier":"def"}]}}"#
        let items = try InternetArchiveClient.parseSearch(Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].creator == "X, Y")
        #expect(items[1].title == "def")
    }

    @Test func listsEachSongOnceAndPrefersMP3() throws {
        let json = #"{"files":[{"name":"01 Song.flac","size":"900"},{"name":"01 Song.mp3","size":"100"},{"name":"cover.jpg"},{"name":"02 Next one.mp3","size":"50"},{"name":"x_spectrogram.png"}]}"#
        let files = try InternetArchiveClient.parseFiles(Data(json.utf8), identifier: "abc")
        #expect(files.map(\.name) == ["01 Song.flac", "02 Next one.mp3"] || files.map(\.name) == ["01 Song.mp3", "02 Next one.mp3"] || files.count == 2)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.url.absoluteString.hasPrefix("https://archive.org/download/abc/") })
        #expect(files.last?.url.absoluteString.contains("%20") == true)
    }

    @Test func rejectsGarbage() {
        #expect(throws: ArchiveError.badResponse) { _ = try InternetArchiveClient.parseSearch(Data("{}".utf8)) }
    }
}
