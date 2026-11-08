#if os(iOS)
import SwiftUI
import Domain

struct FullPlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let playback = app.playback
        VStack(spacing: 22) {
            HStack {
                Button("Close", systemImage: "chevron.down") { dismiss() }
                    .labelStyle(.iconOnly).font(.title3.weight(.semibold)).buttonStyle(.plain)
                Spacer()
                Text("Now Playing").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }
            Spacer(minLength: 0)
            if let track = playback.current {
                ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 380, cornerRadius: 22)
                    .frame(maxWidth: 380)
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                    .scaleEffect(playback.isPlaying ? 1 : 0.9)
                    .animation(.spring(duration: 0.45, bounce: 0.3), value: playback.isPlaying)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(2)
                        Text(track.artist.isEmpty ? String(localized: "Unknown artist") : track.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            if let file = track.file {
                                SourceBadge(source: TrackSource(raw: file.source))
                                Text(file.format.summary).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                    Button(track.isFavorite ? "Unfavorite" : "Favorite", systemImage: track.isFavorite ? "heart.fill" : "heart") {
                        Task { await app.library.edit(track.id, TrackEdit(isFavorite: !track.isFavorite)) }
                    }
                    .labelStyle(.iconOnly).font(.title2).foregroundStyle(track.isFavorite ? Theme.accent2 : .secondary)
                    .symbolEffect(.bounce, value: track.isFavorite)
                }
                if playback.isLoading {
                    ProgressView("Getting the song from your other device…")
                } else {
                    ScrubberView(elapsed: playback.elapsed, duration: playback.duration, onSeek: playback.seek)
                }
                TransportControls().font(.title)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background {
            ZStack {
                Rectangle().fill(.background)
                if let key = playback.current?.artworkKey {
                    ArtworkView(key: key, seed: playback.current?.id ?? UUID(), maxPoints: 120, cornerRadius: 0).blur(radius: 60).opacity(0.45)
                }
                RadialGradient(colors: [Theme.accent.opacity(0.3), .clear], center: .top, startRadius: 20, endRadius: 520)
            }
            .ignoresSafeArea()
        }
        .tint(Theme.accent)
    }
}
#endif
