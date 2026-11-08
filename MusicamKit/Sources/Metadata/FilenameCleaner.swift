import Foundation

public struct CleanedName: Equatable, Sendable {
    public var artist: String?
    public var title: String
}

/// Turns the file names that downloads usually have ("07_Zedbazi_-_Bache_Mahal_[320]_[www.site.com].mp3")
/// into an artist and a title.
public enum FilenameCleaner {
    private static let junkWords = [
        "official", "audio", "video", "lyric", "lyrics", "hd", "hq", "kbps", "download", "free", "www", ".com", ".ir", ".net", ".org",
        "320", "256", "192", "160", "128", "remastered download", "دانلود", "سایت", "موزیک", "آهنگ جدید",
    ]

    /// Removes site names, quality tags and other leftovers from a piece of text.
    public static func stripJunk(_ text: String) -> String {
        var s = text
        // bracketed groups that are only junk: [320], (Official Audio), [www.site.com]
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\{[^}]*\}"#] {
            s = replace(pattern, in: s) { group in isJunkGroup(group) ? "" : nil }
        }
        // bare domains and URLs
        s = replace(#"(?i)(https?://\S+|\bwww\.\S+|\b[a-z0-9-]+\.(?:com|ir|net|org|info|co|me|tv|ly)\b)"#, in: s) { _ in "" }
        // ♫ … ♫ decorations that music sites add
        s = replace(#"[♫♪♬][^♫♪♬]*[♫♪♬]?"#, in: s) { _ in "" }
        return normalizeSpaces(s)
    }

    public static func clean(filename: String) -> CleanedName {
        let stem = (filename as NSString).deletingPathExtension
        var s = stem.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        s = stripJunk(s)
        // a leading track number: "07 - ", "07. ", "07) "
        s = replace(#"^\s*\d{1,3}\s*[-.)]\s*"#, in: s) { _ in "" }
        // "07 Artist - Title": a bare number is a track number only when an "Artist - Title" split follows
        s = replace(#"^\s*\d{1,3}\s+(?=\S.* - )"#, in: s) { _ in "" }
        s = normalizeSpaces(s)
        if let range = s.range(of: " - ") {
            let artist = normalizeSpaces(String(s[s.startIndex..<range.lowerBound]))
            let title = normalizeSpaces(String(s[range.upperBound...]))
            if !artist.isEmpty, !title.isEmpty { return CleanedName(artist: artist, title: title) }
        }
        return CleanedName(artist: nil, title: s)
    }

    /// Names like "track 07" or "audio 3" say nothing about the song.
    public static func isGeneric(_ title: String) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        // "Song" or "Music" alone can be a real title; only a number after the word (or "untitled"/"unknown") makes it generic
        if t.range(of: #"^(track|audio|song|music|voice)\s*[-_ ]*\d+$"#, options: .regularExpression) != nil { return true }
        if t == "untitled" || t == "unknown" { return true }
        if t.range(of: #"^\d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: Helpers

    private static func isJunkGroup(_ group: String) -> Bool {
        let inner = group.dropFirst().dropLast().lowercased()
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if inner.range(of: #"^\s*\d{2,3}\s*(k|kbps)?\s*$"#, options: .regularExpression) != nil { return true }   // [320], (128k)
        return junkWords.contains { inner.contains($0) }
    }

    private static func normalizeSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-.,_")))
    }

    private static func replace(_ pattern: String, in text: String, with transform: (String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            if let replacement = transform(String(result[range])) { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}
