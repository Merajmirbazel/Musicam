#if os(macOS)
import SwiftUI

/// The always-visible player: what is playing, transport controls, position, volume.
struct PlayerBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var playback = app.playback
        HStack(spacing: 24) {
            NowPlayingSummary()
                .frame(width: 250, alignment: .leading)
            VStack(spacing: 2) {
                TransportControls()
                ScrubberView(elapsed: playback.elapsed, duration: playback.duration, onSeek: playback.seek)
                    .frame(maxWidth: 520)
                    .disabled(playback.current == nil)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                if let format = playback.current?.file?.format {
                    Text(format.codec)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .rect(cornerRadius: 5))
                        .help(format.summary)
                }
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $playback.volume, in: 0...1)
                    .frame(width: 90)
                    .controlSize(.small)
                    .accessibilityLabel("Volume")
            }
            .frame(width: 250, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: playback.volume) { app.rememberVolume() }
    }
}
#endif
