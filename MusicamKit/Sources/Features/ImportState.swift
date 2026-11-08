import Foundation
import Importing

public enum ImportState: Equatable, Sendable {
    case idle
    case running(done: Int, total: Int, name: String)
    case finished(ImportSummary)

    /// A one-line, human-readable result.
    public static func message(for summary: ImportSummary) -> String {
        if summary.total == 0 { return String(localized: "No audio files found.") }
        var parts: [String] = []
        if summary.imported > 0 { parts.append(String(localized: "Added \(summary.imported) songs")) }
        if summary.duplicates > 0 { parts.append(String(localized: "\(summary.duplicates) already in your library")) }
        if summary.unchanged > 0 { parts.append(String(localized: "\(summary.unchanged) unchanged")) }
        if summary.unsupported > 0 { parts.append(String(localized: "\(summary.unsupported) in a format that cannot be played (Ogg)")) }
        if summary.failed > 0 { parts.append(String(localized: "\(summary.failed) could not be read")) }
        return parts.isEmpty ? String(localized: "Nothing to add.") : parts.joined(separator: " · ") + "."
    }
}
