#if os(macOS)
import SwiftUI
import Domain

/// Large cover, details and the queue.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        HStack(alignment: .center, spacing: 48) {
            if let track = playback.current {
                VStack(alignment: .leading, spacing: 14) {
                    ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 420, cornerRadius: 18)
                        .frame(maxWidth: 420)
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                    Text(track.title).font(.title.bold()).lineLimit(2)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.title3).foregroundStyle(.secondary).lineLimit(2)
                    if let format = track.file?.format {
                        Text(format.summary)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .rect(cornerRadius: 6))
                    }
                }
                .frame(maxWidth: 420)
                UpNextList(tracks: Array(playback.upcoming.prefix(8)))
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.slash",
                                       description: Text("Double-click a song to play it."))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topLeading) {
            RadialGradient(colors: [Color.accentColor.opacity(0.22), .clear], center: .topLeading, startRadius: 40, endRadius: 700)
                .ignoresSafeArea()
        }
        .navigationTitle("Now Playing")
    }
}
#endif
