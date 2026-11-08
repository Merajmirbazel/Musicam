import Foundation
import Domain

public enum TagIssue: Hashable, Sendable {
    case missingArtist
    case missingAlbum
    case missingTitle
    case titleLooksLikeFilename
    case genericTitle
    case junkInText(field: String)
    case garbledText(field: String)
    case noArtwork
    case suspiciousYear
}

/// Finds what is wrong with a song's tags. Pure and fast: runs over the whole library.
public enum TagSanity {
    private static let unknownArtists: Set<String> = ["unknown", "unknown artist", "<unknown>", "various", "artist", "نامشخص", "ناشناس"]

    public static func issues(for track: Track) -> [TagIssue] {
        var found: [TagIssue] = []
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        if artist.isEmpty || unknownArtists.contains(artist.lowercased()) { found.append(.missingArtist) }
        if track.album.trimmingCharacters(in: .whitespaces).isEmpty { found.append(.missingAlbum) }

        let title = track.title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty {
            found.append(.missingTitle)
        } else {
            if FilenameCleaner.isGeneric(title) { found.append(.genericTitle) }
            if let name = track.file?.originalFilename, looksLikeFilename(title, filename: name) { found.append(.titleLooksLikeFilename) }
        }
        for (field, value) in [("title", track.title), ("artist", track.artist), ("album", track.album), ("albumArtist", track.albumArtist)] {
            if MojibakeRepair.repaired(value) != nil { found.append(.garbledText(field: field)) }
            else if FilenameCleaner.stripJunk(value) != value.trimmingCharacters(in: .whitespaces), !value.isEmpty { found.append(.junkInText(field: field)) }
        }
        if track.artworkKey == nil { found.append(.noArtwork) }
        if let year = track.year, !(1900...maxPlausibleYear()).contains(year) { found.append(.suspiciousYear) }
        return found
    }

    /// Next calendar year, in the Gregorian calendar. `Calendar.current` must not be used here: with a Persian
    /// device language it is the Persian calendar (year 1405), which made the range 1900...1406 invalid and crashed.
    static func maxPlausibleYear(now: Date = .now) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: now) + 1
    }

    private static func looksLikeFilename(_ title: String, filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        if title == stem, title.contains("_") || title.contains("[") || title.contains(" - ") || title.lowercased().contains("www") { return true }
        return title.contains("_") && title.range(of: #"\s"#, options: .regularExpression) == nil
    }

    /// Groups of songs that are probably the same recording (same artist and title, nearly the same length).
    public static func duplicateGroups(in tracks: [Track]) -> [[Track]] {
        func key(_ t: Track) -> String {
            normalize(t.artist) + "|" + normalize(t.title)
        }
        var buckets: [String: [Track]] = [:]
        for track in tracks where !normalize(track.title).isEmpty { buckets[key(track), default: []].append(track) }
        var groups: [[Track]] = []
        for (_, members) in buckets where members.count > 1 {
            // keep only members whose length is within 3 seconds of the first
            let first = members[0]
            let close = members.filter { abs($0.duration - first.duration) <= 3 }
            let distinctFiles = Set(close.compactMap { $0.file?.contentHash })
            if close.count > 1, distinctFiles.count > 1 || close.contains(where: { $0.file == nil }) { groups.append(close.sorted { quality($0) > quality($1) }) }
        }
        return groups.sorted { $0[0].title.localizedStandardCompare($1[0].title) == .orderedAscending }
    }

    /// Higher is better: lossless beats a higher bitrate, then more tags win.
    public static func quality(_ track: Track) -> Int {
        var score = 0
        if let format = track.file?.format {
            score += format.isLossless ? 1_000_000 : (format.bitrate ?? 0) / 1000
        }
        score += (track.artworkKey == nil ? 0 : 5) + (track.album.isEmpty ? 0 : 3) + (track.year == nil ? 0 : 1)
        return score
    }

    /// Lowercase, no accents, no punctuation: so "Café Blue!" and "cafe blue" match.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0.value > 0x7F && $0.properties.isAlphabetic }
            .map(String.init).joined()
    }
}
