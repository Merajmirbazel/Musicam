import Foundation

public struct YTCandidate: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let duration: Double?
    public init(id: String, title: String?, duration: Double?) {
        self.id = id
        self.title = title
        self.duration = duration
    }
}

/// Port of the Python matcher: never ship the wrong audio under the right cover.
public enum YouTubeMatcher {
    public static let durationToleranceWide: Double = 30

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    private static let parens = re(#"\([^)]*\)"#)
    private static let brackets = re(#"\[[^\]]*\]"#)
    private static let featTail = re(#"\b(feat\.?|ft\.?)\s+.*$"#, .caseInsensitive)
    private static let spaces = re(#"\s+"#)
    private static let artistSplit = re(#"[,&]+|\s+(?:feat\.?|ft\.?)\s+"#, .caseInsensitive)
    private static let latin = re(#"[a-z0-9]"#)

    private static func sub(_ r: NSRegularExpression, _ s: String, _ with: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// Lowercase, strip diacritics, drop bracketed segments + feat. tails,
    /// keep letters/numbers/marks of any script (NOT splitting on " - ").
    public static func normalizeTitle(_ input: String?) -> String {
        guard let input, !input.isEmpty else { return "" }
        var kept = String.UnicodeScalarView()
        for sc in input.decomposedStringWithCompatibilityMapping.unicodeScalars
        where sc.properties.canonicalCombiningClass == .notReordered {
            kept.append(sc)
        }
        var s = String(kept).lowercased()
        s = sub(parens, s, " ")
        s = sub(brackets, s, " ")
        s = sub(featTail, s, "")
        s = s.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        var out = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            let cat = sc.properties.generalCategory
            let keep: Bool
            if sc.properties.isWhitespace { keep = true } else {
                switch cat {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber,
                     .nonspacingMark, .spacingMark, .enclosingMark:
                    keep = true
                default: keep = false
                }
            }
            out.append(keep ? sc : " ")
        }
        return sub(spaces, String(out), " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop the " - Variant" suffix Spotify adds ("Song - Remastered 2011" -> "Song").
    public static func spotifyTitleCore(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if let r = s.range(of: " - ") { return String(s[..<r.lowerBound]) }
        return s
    }

    public static func titlePlausiblyMatches(ytTitle: String?, expectedTitle: String?) -> Bool {
        let yt = normalizeTitle(ytTitle)
        let target = normalizeTitle(spotifyTitleCore(expectedTitle))
        if target.isEmpty || yt.isEmpty { return false }
        if target.count >= 4 { return yt.contains(target) }
        return yt.split(separator: " ").contains(Substring(target))
    }

    public static func widenSearch(_ q: String) -> String {
        q.hasPrefix("ytsearch1:") ? "ytsearch5:" + q.dropFirst("ytsearch1:".count) : q
    }

    public static func simplifySearch(_ q: String) -> String {
        let terms: String
        if let i = q.firstIndex(of: ":") { terms = String(q[q.index(after: i)...]) } else { terms = q }
        var stripped = sub(re(#"[\(\[\{].*?[\)\]\}]"#), terms, " ")
        stripped = sub(spaces, stripped, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty || stripped == terms.trimmingCharacters(in: .whitespacesAndNewlines) { return q }
        return "ytsearch5:\(stripped)"
    }

    private static func closest(_ pool: [YTCandidate], to expected: Double?) -> YTCandidate? {
        guard var chosen = pool.first else { return nil }
        if let expected, expected > 0 {
            let timed = pool.filter { ($0.duration ?? 0) > 0 }
            if let best = timed.min(by: { abs($0.duration! - expected) < abs($1.duration! - expected) }) {
                chosen = best
            }
        }
        return chosen
    }

    /// Returns the chosen YouTube video id, or nil when nothing is a confident match.
    public static func select(candidates: [YTCandidate], expectedTitle: String?, expectedArtists: String?,
                              expectedDuration: Double?, looseMatch: Bool) -> String? {
        let entries = candidates.filter { !$0.id.isEmpty }
        if entries.isEmpty { return nil }

        guard let expectedTitle, !expectedTitle.isEmpty else {
            // legacy: trust the top hit unless its duration is clearly off
            var chosen = entries[0]
            if let exp = expectedDuration, exp > 0 {
                let topOff = chosen.duration == nil || abs(chosen.duration! - exp) > 7
                if topOff, let best = closest(entries, to: exp) { chosen = best }
            }
            return chosen.id
        }

        let titleOK = entries.filter { titlePlausiblyMatches(ytTitle: $0.title, expectedTitle: expectedTitle) }
        if titleOK.isEmpty { return looseMatch ? closest(entries, to: expectedDuration)?.id : nil }

        var pool = titleOK
        if let artists = expectedArtists, !artists.isEmpty {
            let marked = sub(artistSplit, artists, "\u{1}")
            let tokens = marked.split(separator: "\u{1}").map { normalizeTitle(String($0)) }.filter { !$0.isEmpty }
            if !tokens.isEmpty {
                pool = titleOK.filter { e in
                    let t = normalizeTitle(e.title ?? "")
                    return tokens.contains { t.contains($0) }
                }
                let anyLatin = tokens.contains {
                    latin.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }
                if pool.isEmpty && !anyLatin { pool = titleOK }  // native-script artists
                if pool.isEmpty { return looseMatch ? closest(titleOK, to: expectedDuration)?.id : nil }
            }
        }

        guard var chosen = pool.first else { return nil }
        if let exp = expectedDuration, exp > 0 {
            let timed = pool.filter { ($0.duration ?? 0) > 0 }
            if let best = timed.min(by: { abs($0.duration! - exp) < abs($1.duration! - exp) }) {
                chosen = best
                if abs(best.duration! - exp) > durationToleranceWide { return nil }
            }
        }
        return chosen.id
    }
}
