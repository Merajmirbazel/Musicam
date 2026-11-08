import Foundation

/// Older MP3 files often store Persian or Arabic text in the Windows-1256 code page, which a player that assumes
/// Western text shows as "ÇáÓáÇã". This turns it back into real letters.
public enum MojibakeRepair {
    private static let arabicCP1256 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))

    /// The repaired text, or nil when the text does not look garbled (or cannot be repaired with confidence).
    public static func repaired(_ text: String) -> String? {
        guard !text.isEmpty, !containsArabicScript(text) else { return nil }
        let scalars = text.unicodeScalars
        guard scalars.contains(where: { $0.value >= 0x80 }), scalars.allSatisfy({ $0.value < 0x250 || $0.properties.isWhitespace }) else { return nil }
        guard let bytes = text.data(using: .windowsCP1252) else { return nil }

        // 1) Windows-1256 bytes read as Western text
        if let arabic = String(data: bytes, encoding: arabicCP1256), arabicLetterShare(arabic) >= 0.6 {
            return PersianNormalizer.normalize(arabic)
        }
        // 2) UTF-8 bytes read as Western text ("Ã©" for "é")
        if let utf8 = String(data: bytes, encoding: .utf8), utf8 != text, !utf8.contains("\u{FFFD}") { return utf8 }
        return nil
    }

    public static func containsArabicScript(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFB50...0xFEFF).contains($0.value) }
    }

    /// Share of letters (ignoring spaces and punctuation) that are Arabic-script letters.
    private static func arabicLetterShare(_ s: String) -> Double {
        let letters = s.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return 0 }
        let arabic = letters.filter { (0x0600...0x06FF).contains($0.value) }.count
        return Double(arabic) / Double(letters.count)
    }
}

/// Windows tools write Persian with the Arabic forms of "ye" and "kaf"; Persian readers expect the Persian ones.
public enum PersianNormalizer {
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{064A}", with: "\u{06CC}")     // ي -> ی
            .replacingOccurrences(of: "\u{0649}", with: "\u{06CC}")     // ى -> ی
            .replacingOccurrences(of: "\u{0643}", with: "\u{06A9}")     // ك -> ک
    }
}
