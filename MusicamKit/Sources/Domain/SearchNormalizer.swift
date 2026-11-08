import Foundation

/// Makes Persian, Arabic and Latin text comparable for search: the Arabic and Persian forms of ye and kaf are the same
/// letter, half-spaces and vowel marks are ignored, every kind of digit becomes 0-9, and case, accents and width do not matter.
public enum SearchNormalizer {
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            switch u.value {
            case 0x064A, 0x0649, 0x06D2: scalars.append("\u{06CC}")            // ي ى ے -> ی
            case 0x0643: scalars.append("\u{06A9}")                              // ك -> ک
            case 0x0629: scalars.append("\u{0647}")                              // ة -> ه
            case 0x0623, 0x0625, 0x0671: scalars.append("\u{0627}")              // أ إ ٱ -> ا
            case 0x200C, 0x200D, 0x200E, 0x200F, 0x0640: continue                // half-space, joiners, direction marks, tatweel
            case 0x064B...0x065F, 0x0670: continue                               // Arabic vowel marks
            case 0x0660...0x0669: scalars.append(Unicode.Scalar(UInt8(48 + u.value - 0x0660)))   // Arabic-Indic digits
            case 0x06F0...0x06F9: scalars.append(Unicode.Scalar(UInt8(48 + u.value - 0x06F0)))   // Persian digits
            default: scalars.append(u)
            }
        }
        return String(scalars).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Every word of the query must appear somewhere in the fields (title, artist, album).
    public static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = fields.map(normalize).joined(separator: " ")
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Higher is a better match: the title starting with the query beats the title containing it, which beats artist and album.
    public static func score(_ query: String, title: String, artist: String, album: String) -> Int {
        let q = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let t = normalize(title), a = normalize(artist), b = normalize(album)
        var score = 0
        if t == q { score += 100 } else if t.hasPrefix(q) { score += 80 } else if t.contains(q) { score += 60 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { score += 10 }
        if a.contains(q) { score += 30 }
        if b.contains(q) { score += 15 }
        return score
    }
}
