import Foundation

public enum FileNaming {
    private static let reservedChars: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
    private static let reservedDevices: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 1...9 { s.insert("COM\(i)"); s.insert("LPT\(i)") }
        for sup in ["¹", "²", "³"] { s.insert("COM\(sup)"); s.insert("LPT\(sup)") }
        return s
    }()

    /// Cross-platform safe filename component (port of sanitize_filename).
    public static func sanitize(_ name: String, allowSpaces: Bool = true) -> String {
        let nfc = name.precomposedStringWithCanonicalMapping
        var kept = String.UnicodeScalarView()
        for sc in nfc.unicodeScalars {
            if reservedChars.contains(Character(sc)) { continue }
            if sc.properties.generalCategory == .control { continue }
            kept.append(sc)
        }
        var s = String(kept)
        if !allowSpaces { s = s.replacingOccurrences(of: " ", with: "") }
        if allowSpaces {
            s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        } else {
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if s.isEmpty { return "Unknown" }
        let base = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        if reservedDevices.contains(base.uppercased()) { s = "_" + s }
        return s
    }

    /// Cap a full filename (incl. extension) to 250 UTF-8 bytes (port of cap_filename).
    public static func cap(_ name: String, maxBytes: Int = 250) -> String {
        if name.utf8.count <= maxBytes { return name }
        var stem = name
        var ext = ""
        if let dot = name.lastIndex(of: ".") {
            let e = String(name[name.index(after: dot)...])
            if !e.isEmpty, e.count <= 10, !e.contains(" ") {
                stem = String(name[..<dot])
                ext = e
            }
        }
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let budget = max(1, maxBytes - suffix.utf8.count)
        var cut = ""
        var used = 0
        for ch in stem {
            let n = String(ch).utf8.count
            if used + n > budget { break }
            cut.append(ch)
            used += n
        }
        cut = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cut.isEmpty ? "file\(suffix)" : cut + suffix
    }

    /// Filename from the naming settings (port of _compose_filename).
    public static func compose(title: String, artists: String, options: DownloadOptions,
                               trackNumber: Int? = nil, disambig: String? = nil) -> String {
        let t = sanitize(title)
        let a = sanitize(artists)
        var stem: String
        if options.titleOnly {
            stem = t.isEmpty ? (a.isEmpty ? "track" : a) : t
        } else if options.artistFirst {
            stem = "\(a) - \(t)"
        } else {
            stem = "\(t) - \(a)"
        }
        if let d = disambig { stem += " [\(d)]" }
        let ext = options.format.ext
        if options.includeTrackNumber, let n = trackNumber {
            return String(format: "%02d. ", n) + "\(stem).\(ext)"
        }
        return "\(stem).\(ext)"
    }
}
