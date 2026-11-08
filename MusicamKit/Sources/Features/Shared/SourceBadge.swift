import SwiftUI
import Domain

/// Shows where a song came from, with an icon and a label. Only what is really known is shown: a file picked by hand is
/// "Imported", a song from an older version that never recorded its origin shows "Imported" too (its origin is unknown,
/// and the app does not guess a service).
struct SourceBadge: View {
    let source: TrackSource
    var showsLabel = true

    var body: some View {
        Label {
            if showsLabel { Text(title) }
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, showsLabel ? 7 : 5)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Source: \(title)"))
    }

    var title: String {
        switch source {
        case .unknown, .file: String(localized: "Imported")
        case .folder: String(localized: "Folder")
        case .watched: String(localized: "Watched folder")
        case .telegram: String(localized: "Telegram")
        case .shared: String(localized: "Shared")
        case .link(let host): host
        }
    }

    var symbol: String {
        switch source {
        case .unknown, .file: "square.and.arrow.down"
        case .folder: "folder.fill"
        case .watched: "folder.badge.gearshape"
        case .telegram: "paperplane.fill"
        case .shared: "square.and.arrow.up.on.square"
        case .link: "link"
        }
    }

    var tint: Color {
        switch source {
        case .telegram: .blue
        case .link: .orange
        case .shared, .watched: .teal
        default: .secondary
        }
    }
}

/// Where a wished-for song was found. These are the pages the link points to, not where audio came from.
struct WishSourceBadge: View {
    let url: URL

    var body: some View {
        let host = (url.host ?? "").lowercased()
        let (name, symbol, tint): (String, String, Color) =
            host.contains("spotify") ? ("Spotify", "waveform.circle.fill", .green)
            : host.contains("youtu") ? ("YouTube", "play.rectangle.fill", .red)
            : host.contains("soundcloud") ? ("SoundCloud", "cloud.fill", .orange)
            : (host, "link", .secondary)
        Label(name, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: .capsule)
    }
}
