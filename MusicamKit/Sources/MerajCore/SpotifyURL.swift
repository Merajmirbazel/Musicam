import Foundation

public enum SpotifyURL {
    // Accepts canonical https://open.spotify.com/{type}/{id}, the locale form
    // /intl-xx/{type}/{id}, and spotify:{type}:{id}. Trailing ?si=... is tolerated.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?://open\.spotify\.com/(?:intl-[a-z]{2,}/)?|spotify:)(playlist|track|album)[/:]([a-zA-Z0-9]+)"#
    )

    public static func parse(_ input: String) throws -> SpotifyLink {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw MerajError.invalidURL("Empty Spotify URL.") }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = pattern.firstMatch(in: s, range: range),
              let r1 = Range(m.range(at: 1), in: s),
              let r2 = Range(m.range(at: 2), in: s),
              let kind = SpotifyKind(rawValue: String(s[r1]))
        else {
            throw MerajError.invalidURL("Invalid Spotify URL. Must be a track, playlist, or album URL.")
        }
        return SpotifyLink(kind: kind, id: String(s[r2]))
    }
}
