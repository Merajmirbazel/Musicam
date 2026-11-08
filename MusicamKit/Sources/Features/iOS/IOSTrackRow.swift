#if os(iOS)
import SwiftUI
import Domain

/// One song in a list: cover, title, artist, where it came from, and whether it is on this device.
struct IOSTrackRow: View {
    @Environment(AppModel.self) private var app
    let track: Track
    var showsPlayCount = false

    var body: some View {
        let isCurrent = app.playback.current?.id == track.id
        let stored = app.library.isStoredHere(track)
        let progress = track.file.flatMap { app.sync.downloads[$0.id] }
        HStack(spacing: 12) {
            ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 52, cornerRadius: 8)
                .frame(width: 52, height: 52)
                .overlay {
                    if isCurrent {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
                            Image(systemName: app.playback.isPlaying ? "waveform" : "pause.fill").foregroundStyle(.white).symbolEffect(.variableColor.iterative, isActive: app.playback.isPlaying)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if track.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Theme.accent2) }
                    Text(track.artist.isEmpty ? String(localized: "Unknown artist") : track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if showsPlayCount { Text("· \(app.stats.playCount(track.id))").font(.caption).foregroundStyle(.tertiary) }
                }
                if let file = track.file { SourceBadge(source: TrackSource(raw: file.source)) }
            }
            Spacer(minLength: 4)
            if let progress {
                ProgressView(value: progress).progressViewStyle(.circular).frame(width: 26, height: 26)
            } else if !stored {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).accessibilityLabel("Not on this device yet")
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}
#endif
