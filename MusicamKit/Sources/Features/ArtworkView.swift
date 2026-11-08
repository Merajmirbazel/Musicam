import SwiftUI

/// A square cover. Falls back to a gradient picked from the song's ID, so songs without art still look distinct.
struct ArtworkView: View {
    /// Optional on purpose: table cells are hosted in their own views, and a missing environment must not crash the app.
    @Environment(AppModel.self) private var app: AppModel?
    let key: String?
    let seed: UUID
    var maxPoints: CGFloat = 80
    var cornerRadius: CGFloat = 8
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                Placeholder(seed: seed)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .task(id: LoadID(key: key, revision: app?.artwork.revision ?? 0)) { await load() }
        .accessibilityHidden(true)
    }

    private struct LoadID: Hashable { let key: String?; let revision: Int }

    private func load() async {
        image = await app?.artwork.image(for: key, maxPoints: maxPoints)
    }

    private struct Placeholder: View {
        let seed: UUID
        private static let palette: [[Color]] = [
            [.purple, .pink], [.orange, .red], [.cyan, .indigo], [.green, .blue], [.pink, .orange], [.indigo, .teal], [.teal, .mint],
        ]
        var body: some View {
            let colors = Self.palette[Int(seed.uuid.0) % Self.palette.count]
            GeometryReader { proxy in
                ZStack {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: proxy.size.width * 0.42, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }
}
