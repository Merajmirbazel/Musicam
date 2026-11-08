import Testing
import Foundation
@testable import Metadata

@Suite struct LinkTests {
    @Test func classifiesLinks() {
        #expect(LinkParser.classify("https://open.spotify.com/track/abc123?si=x") == .spotify(url: URL(string: "https://open.spotify.com/track/abc123?si=x")!))
        #expect(LinkParser.classify("spotify:track:abc123") == .spotify(url: URL(string: "https://open.spotify.com/track/abc123")!))
        if case .youtube = LinkParser.classify("https://youtu.be/xyz") {} else { Issue.record("youtu.be") }
        if case .youtube = LinkParser.classify("https://www.youtube.com/watch?v=xyz") {} else { Issue.record("youtube") }
        if case .directAudio = LinkParser.classify("https://archive.org/download/item/song.mp3") {} else { Issue.record("direct") }
        #expect(LinkParser.classify("https://soundcloud.com/a/b") == .unsupportedService(host: "soundcloud.com"))
        #expect(LinkParser.classify("https://music.apple.com/us/album/x") == .unsupportedService(host: "music.apple.com"))
        if case .directAudio = LinkParser.classify("https://bandcamp.com/files/purchase.flac") {} else { Issue.record("bought file on a store host") }
        #expect(LinkParser.classify("hello world") == .notALink)
        #expect(LinkParser.classify("https://example.com/page.html") == .notALink)
        #expect(LinkParser.classify("ftp://example.com/a.mp3") == .notALink)
    }

    @Test func readsYouTubeAndSpotifyTitles() throws {
        let yt = Data(#"{"title":"Kian - Night Walk (Official Audio)","author_name":"Some Channel","thumbnail_url":"https://i.ytimg.com/x.jpg"}"#.utf8)
        let a = try OEmbedClient.parse(yt, isYouTube: true)
        #expect(a.artist == "Kian" && a.title == "Night Walk")
        let topic = Data(#"{"title":"Night Walk","author_name":"Kian - Topic"}"#.utf8)
        let b = try OEmbedClient.parse(topic, isYouTube: true)
        #expect(b.artist == "Kian" && b.title == "Night Walk")
        let sp = Data(#"{"title":"Night Walk","thumbnail_url":"https://i.scdn.co/y"}"#.utf8)
        let c = try OEmbedClient.parse(sp, isYouTube: false)
        #expect(c.title == "Night Walk" && c.artist == "" && c.thumbnailURL != nil)
        #expect(throws: LinkError.badResponse) { _ = try OEmbedClient.parse(Data("{}".utf8), isYouTube: false) }
    }

    @Test func wishlistKeepsItemsAndRefusesRepeats() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wish-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WishlistStore(url: url)
        let link = URL(string: "https://open.spotify.com/track/1")!
        #expect(await store.add(WishItem(title: "A", artist: "B", sourceURL: link)))
        #expect(await store.add(WishItem(title: "A again", artist: "B", sourceURL: link)) == false)
        let reopened = WishlistStore(url: url)
        let all = await reopened.all()
        #expect(all.count == 1)
        await reopened.remove(all[0].id)
        #expect(await WishlistStore(url: url).all().isEmpty)
    }

    @Test func wishMatchingIsLooseButNotSloppy() {
        let wish = WishItem(title: "Café Blue!", artist: "Marlow", sourceURL: URL(string: "https://x.example/1")!)
        #expect(WishMatcher.matches(wish, title: "cafe blue", artist: "Marlow"))
        #expect(WishMatcher.matches(wish, title: "Cafe Blue", artist: "Marlow & Friends"))
        #expect(WishMatcher.matches(wish, title: "Cafe Blue", artist: ""))
        #expect(!WishMatcher.matches(wish, title: "Cafe Blue", artist: "Someone Else"))
        #expect(!WishMatcher.matches(wish, title: "Another Song", artist: "Marlow"))
        let video = WishItem(title: "Never Gonna Give You Up (4K Remaster)", artist: "Rick Astley", sourceURL: URL(string: "https://x.example/2")!)
        #expect(WishMatcher.matches(video, title: "Never Gonna Give You Up", artist: "Rick Astley"))
    }
}
