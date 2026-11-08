#if os(macOS)
import SwiftUI
import Domain

/// The first table column: cover, a speaker mark on the song that is playing, and the title.
struct TitleCell: View {
    @Environment(AppModel.self) private var app: AppModel?   // optional: see ArtworkView
    let track: Track

    var body: some View {
        let isCurrent = app?.playback.current?.id == track.id
        HStack(spacing: 10) {
            ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 34, cornerRadius: 5)
                .frame(width: 32, height: 32)
            if isCurrent {
                Image(systemName: app?.playback.isPlaying == true ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Now playing")
            }
            Text(track.title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)
        }
    }
}
#endif
