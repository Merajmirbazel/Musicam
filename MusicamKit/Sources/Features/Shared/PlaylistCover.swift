import SwiftUI
import Domain

/// A playlist's picture: the covers of its first songs in a grid, or a gradient with an icon while it is empty.
struct PlaylistCover: View {
    @Environment(AppModel.self) private var app
    let playlist: Playlist
    var cornerRadius: CGFloat = 12

    var body: some View {
        let tracks = Array(app.playlists.tracks(of: playlist).prefix(4))
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                if tracks.isEmpty {
                    Theme.gradient
                    Image(systemName: "music.note.list").font(.system(size: side * 0.36, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                } else if tracks.count < 4 {
                    ArtworkView(key: tracks[0].artworkKey, seed: tracks[0].id, maxPoints: side, cornerRadius: 0)
                } else {
                    let cell = side / 2
                    VStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<2, id: \.self) { col in
                                    let t = tracks[row * 2 + col]
                                    ArtworkView(key: t.artworkKey, seed: t.id, maxPoints: cell, cornerRadius: 0)
                                        .frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
