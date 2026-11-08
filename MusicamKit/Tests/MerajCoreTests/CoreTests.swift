import Foundation
import Testing
@testable import MerajCore

@Suite struct URLTests {
    @Test func canonical() throws {
        let l = try SpotifyURL.parse("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc")
        #expect(l == SpotifyLink(kind: .track, id: "4uLU6hMCjMI75M1A2tKUQC"))
    }
    @Test func localeAndURI() throws {
        #expect(try SpotifyURL.parse("https://open.spotify.com/intl-de/album/1DFixLWuPkv3KT3TnV35m3").kind == .album)
        #expect(try SpotifyURL.parse("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M").id == "37i9dQZF1DXcBWIGoYBM5M")
    }
    @Test func rejects() {
        #expect(throws: MerajError.self) { try SpotifyURL.parse("") }
        #expect(throws: MerajError.self) { try SpotifyURL.parse("https://example.com/track/abc") }
        #expect(throws: MerajError.self) { try SpotifyURL.parse("https://open.spotify.com/artist/abc") }
    }
}

@Suite struct NamingTests {
    @Test func sanitizeBasics() {
        #expect(FileNaming.sanitize("AC/DC: Back In Black?") == "ACDC Back In Black")
        #expect(FileNaming.sanitize("  ..hidden.. ") == "hidden")
        #expect(FileNaming.sanitize("") == "Unknown")
        #expect(FileNaming.sanitize("???") == "Unknown")
        #expect(FileNaming.sanitize("NUL") == "_NUL")
        #expect(FileNaming.sanitize("con.mp3") == "_con.mp3")
        #expect(FileNaming.sanitize("MONTAGEM BAILÃO") == "MONTAGEM BAILÃO")
        #expect(FileNaming.sanitize("夜に駆ける") == "夜に駆ける")
        #expect(FileNaming.sanitize("a\u{0}b\tc") == "abc")
    }
    @Test func capKeepsExtension() {
        let long = String(repeating: "a", count: 400) + ".mp3"
        let capped = FileNaming.cap(long)
        #expect(capped.utf8.count <= 250)
        #expect(capped.hasSuffix(".mp3"))
        #expect(FileNaming.cap("short.mp3") == "short.mp3")
    }
    @Test func compose() {
        var o = DownloadOptions(format: .mp3)
        #expect(FileNaming.compose(title: "Song", artists: "Art", options: o) == "Song - Art.mp3")
        o.artistFirst = true
        #expect(FileNaming.compose(title: "Song", artists: "Art", options: o) == "Art - Song.mp3")
        o.titleOnly = true
        #expect(FileNaming.compose(title: "Song", artists: "Art", options: o) == "Song.mp3")
        o = DownloadOptions(format: .m4a, includeTrackNumber: true)
        #expect(FileNaming.compose(title: "S", artists: "A", options: o, trackNumber: 3) == "03. S - A.m4a")
        #expect(FileNaming.compose(title: "S", artists: "A", options: o, trackNumber: 3, disambig: "xyz") == "03. S - A [xyz].m4a")
    }
}

@Suite struct MatcherTests {
    @Test func normalize() {
        #expect(YouTubeMatcher.normalizeTitle("Café (Remix) [Edit] feat. Someone") == "cafe")
        #expect(YouTubeMatcher.normalizeTitle("I'm Here") == "im here")
        #expect(YouTubeMatcher.normalizeTitle("The Weeknd - Blinding Lights") == "the weeknd blinding lights")
        #expect(YouTubeMatcher.normalizeTitle("दिल") == "दिल")
        #expect(YouTubeMatcher.spotifyTitleCore("Bohemian Rhapsody - Remastered 2011") == "Bohemian Rhapsody")
        #expect(YouTubeMatcher.spotifyTitleCore("Take-Off") == "Take-Off")
    }
    @Test func shortTitleNeedsWordBoundary() {
        #expect(YouTubeMatcher.titlePlausiblyMatches(ytTitle: "i love you", expectedTitle: "I"))
        #expect(!YouTubeMatcher.titlePlausiblyMatches(ytTitle: "this is nothing", expectedTitle: "i"))
    }
    @Test func rejectsSameArtistDifferentSong() {
        let c = [YTCandidate(id: "wrong", title: "Dj Goja - Mi Chico", duration: 180),
                 YTCandidate(id: "right", title: "Dj Goja - Mi Gente (Official Audio)", duration: 182)]
        let pick = YouTubeMatcher.select(candidates: c, expectedTitle: "Mi Gente", expectedArtists: "DJ Goja",
                                         expectedDuration: 181, looseMatch: false)
        #expect(pick == "right")
    }
    @Test func requiresArtist() {
        let c = [YTCandidate(id: "x", title: "Blinding Lights cover by someone", duration: 200)]
        #expect(YouTubeMatcher.select(candidates: c, expectedTitle: "Blinding Lights", expectedArtists: "The Weeknd",
                                      expectedDuration: 200, looseMatch: false) == nil)
        #expect(YouTubeMatcher.select(candidates: c, expectedTitle: "Blinding Lights", expectedArtists: "The Weeknd",
                                      expectedDuration: 200, looseMatch: true) == "x")
    }
    @Test func rejectsWildDuration() {
        let c = [YTCandidate(id: "ext", title: "The Weeknd - Blinding Lights extended", duration: 600)]
        #expect(YouTubeMatcher.select(candidates: c, expectedTitle: "Blinding Lights", expectedArtists: "The Weeknd",
                                      expectedDuration: 200, looseMatch: false) == nil)
    }
    @Test func nativeScriptArtistFallsBackToTitleOnly() {
        let c = [YTCandidate(id: "a", title: "Yoru ni Kakeru", duration: 260)]
        #expect(YouTubeMatcher.select(candidates: c, expectedTitle: "Yoru ni Kakeru", expectedArtists: "YOASOBI",
                                      expectedDuration: 260, looseMatch: false) == nil)
        #expect(YouTubeMatcher.select(candidates: c, expectedTitle: "Yoru ni Kakeru", expectedArtists: "夜",
                                      expectedDuration: 260, looseMatch: false) == "a")
    }
    @Test func searchQueries() {
        #expect(YouTubeMatcher.widenSearch("ytsearch1:a b audio") == "ytsearch5:a b audio")
        #expect(YouTubeMatcher.simplifySearch("ytsearch1:Song (528 Hz) Artist audio") == "ytsearch5:Song Artist audio")
        #expect(YouTubeMatcher.simplifySearch("ytsearch1:Song Artist audio") == "ytsearch1:Song Artist audio")
    }
}

@Suite struct EmbedParserTests {
    static let html = """
    <html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"settings":{"session":{"accessToken":"tok","accessTokenExpirationTimestampMs":4102444800000}},"data":{"entity":{"name":"My List","subtitle":"Meraj","coverArt":{"sources":[{"url":"small"},{"url":"big"}]},"trackList":[{"uri":"spotify:track:AAA","title":"One","subtitle":"Artist A, Artist B","duration":180000},{"uri":"spotify:episode:ZZZ","title":"skip me"},{"uri":"spotify:track:BBB","title":"Two","subtitle":"Artist C","duration":200000,"audioPreview":{"url":"p"}}]}}}}}}</script></html>
    """

    @Test func parsesPlaylist() throws {
        let data = try EmbedParser.nextData(fromHTML: Self.html)
        let tok = EmbedParser.token(from: data)
        #expect(tok?.token == "tok")
        let e = try EmbedParser.entity(from: data)
        let info = EmbedParser.playlistInfo(from: e)
        #expect(info.name == "My List" && info.owner == "Meraj" && info.coverURL == "big")
        let row = (e["trackList"] as! [[String: Any]])[0]
        let t = EmbedParser.trackFromList(row, id: "AAA")
        #expect(t.title == "One" && t.artists == "Artist A, Artist B" && t.durationMs == 180000)
    }
    @Test func unavailablePage() throws {
        let h = #"<script id="__NEXT_DATA__">{"props":{"pageProps":{"status":404,"title":"x"}}}</script>"#
        let d = try EmbedParser.nextData(fromHTML: h)
        #expect(throws: MerajError.self) { try EmbedParser.entity(from: d) }
    }
    @Test func ogAlbum() {
        let h = #"<meta property="og:description" content="Artist · Tom &amp; Jerry OST · Song · 2020">"#
        #expect(EmbedParser.albumFromOGDescription(html: h) == "Tom & Jerry OST")
        #expect(EmbedParser.albumFromOGDescription(html: "<html></html>") == nil)
    }
}
