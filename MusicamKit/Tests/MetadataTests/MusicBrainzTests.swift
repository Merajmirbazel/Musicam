import Testing
import Foundation
import Domain
@testable import Metadata

@Suite struct MusicBrainzTests {
    private let sample = """
    {"recordings":[{"id":"r1","score":100,"title":"Bache Mahal",
      "artist-credit":[{"name":"Zedbazi"}],
      "releases":[{"id":"rel1","title":"Album X","date":"2011-05-01"}]},
     {"id":"r2","score":60,"title":"Other","artist-credit":[{"name":"Someone"}]}]}
    """

    @Test func parsesResponse() throws {
        let m = try MusicBrainzClient.parse(Data(sample.utf8))
        #expect(m.count == 2)
        #expect(m[0].artist == "Zedbazi")
        #expect(m[0].album == "Album X")
        #expect(m[0].year == 2011)
        #expect(m[0].releaseID == "rel1")
    }

    @Test func rejectsGarbage() {
        #expect(throws: MusicBrainzError.badResponse) { _ = try MusicBrainzClient.parse(Data("{}".utf8)) }
    }

    @Test func fillsBlankArtistAndAlbum() throws {
        let m = try MusicBrainzClient.parse(Data(sample.utf8))
        let t = Track(title: "Bache Mahal")
        let p = MusicBrainzPlanner.proposal(for: t, matches: m)
        #expect(p?.edit.artist == "Zedbazi")
        #expect(p?.edit.album == "Album X")
    }

    @Test func neverReplacesADifferentArtist() throws {
        let m = try MusicBrainzClient.parse(Data(sample.utf8))
        let t = Track(title: "Bache Mahal", artist: "My Friend", album: "Mine")
        #expect(MusicBrainzPlanner.proposal(for: t, matches: m) == nil)
    }

    @Test func ignoresLowScoreOrDifferentTitle() throws {
        let m = try MusicBrainzClient.parse(Data(sample.utf8))
        #expect(MusicBrainzPlanner.proposal(for: Track(title: "Other"), matches: m) == nil)       // score 60
        #expect(MusicBrainzPlanner.proposal(for: Track(title: "Something Else"), matches: m) == nil)
    }

    @Test func rateLimiterSpacesRequests() async throws {
        let limiter = RateLimiter(interval: .milliseconds(120))
        let start = ContinuousClock.now
        for _ in 0..<3 { try await limiter.wait() }
        #expect(ContinuousClock.now - start >= .milliseconds(230))
    }
}
