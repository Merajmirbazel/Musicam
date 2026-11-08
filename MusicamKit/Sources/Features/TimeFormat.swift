import Foundation

/// "3:05", or "1:02:03" for an hour or more. Unknown or negative values show as "0:00".
public func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// "3 hr, 5 min, 12 sec" in the person's language. Used for totals such as a whole library or a playlist.
public func formatLongDuration(_ seconds: TimeInterval) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = [.hour, .minute, .second]
    f.unitsStyle = .abbreviated
    f.zeroFormattingBehavior = .dropAll
    let text = f.string(from: max(0, seconds.rounded())) ?? ""
    return text.isEmpty ? "0" : text
}
