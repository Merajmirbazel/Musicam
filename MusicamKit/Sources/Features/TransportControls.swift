import SwiftUI
import Playback

struct TransportControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        HStack(spacing: 22) {
            Button("Shuffle", systemImage: "shuffle") { playback.setShuffle(!playback.isShuffled) }
                .foregroundStyle(playback.isShuffled ? Theme.accent : Color.secondary)
            Button("Previous", systemImage: "backward.fill", action: playback.previous)
            Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                   action: playback.togglePlay)
                .font(.system(size: 30))
                .keyboardShortcut(.space, modifiers: [])
            Button("Next", systemImage: "forward.fill", action: playback.next)
            Button("Repeat", systemImage: playback.repeatMode == .one ? "repeat.1" : "repeat", action: playback.cycleRepeat)
                .foregroundStyle(playback.repeatMode == .off ? Color.secondary : Theme.accent)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .disabled(playback.current == nil)
    }
}
