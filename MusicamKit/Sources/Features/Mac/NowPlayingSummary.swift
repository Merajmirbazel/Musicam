#if os(macOS)
import SwiftUI

/// The small "what is playing" block at the left of the player bar. Clicking it opens Now Playing.
struct NowPlayingSummary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let track = app.playback.current {
            Button(action: openNowPlaying) {
                HStack(spacing: 12) {
                    ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 48)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).fontWeight(.semibold).lineLimit(1)
                        Text(track.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")
        } else {
            Text("Not Playing")
                .foregroundStyle(.secondary)
        }
    }

    private func openNowPlaying() {
        app.section = .nowPlaying
    }
}
#endif
