#if os(macOS)
import SwiftUI
import Domain

struct UpNextList: View {
    let tracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if tracks.isEmpty {
                Text("Nothing queued after this song.").foregroundStyle(.secondary)
            }
            ForEach(tracks) { track in
                HStack(spacing: 12) {
                    ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 40, cornerRadius: 6)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).fontWeight(.semibold).lineLimit(1)
                        Text(track.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(formatTime(track.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
        }
        .frame(maxWidth: 420, alignment: .topLeading)
    }
}
#endif
