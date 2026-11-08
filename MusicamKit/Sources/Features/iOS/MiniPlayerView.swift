#if os(iOS)
import SwiftUI

/// The small player above the tab bar. Tapping it opens the full player.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var app
    @State private var showPlayer = false

    var body: some View {
        let playback = app.playback
        if let track = playback.current {
            HStack(spacing: 12) {
                Button { showPlayer = true } label: {
                    HStack(spacing: 12) {
                        ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 48, cornerRadius: 8)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(playback.isLoading ? String(localized: "Getting the song from your other device…") : track.artist)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the player")
                if playback.isLoading {
                    ProgressView()
                } else {
                    Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill", action: playback.togglePlay)
                        .labelStyle(.iconOnly).font(.title2).contentTransition(.symbolEffect(.replace))
                    Button("Next", systemImage: "forward.fill", action: playback.next)
                        .labelStyle(.iconOnly).font(.title3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(alignment: .bottom) {
                GeometryReader { proxy in
                    Rectangle().fill(Theme.gradient).frame(width: proxy.size.width * (playback.duration > 0 ? min(1, playback.elapsed / playback.duration) : 0), height: 2)
                }
                .frame(height: 2)
                .clipShape(.rect(cornerRadius: 1))
                .padding(.horizontal, 12)
            }
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .fullScreenCover(isPresented: $showPlayer) { FullPlayerView().environment(app) }
        }
    }
}
#endif
