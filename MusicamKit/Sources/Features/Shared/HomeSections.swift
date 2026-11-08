import SwiftUI
import Domain

/// The four lists on the Home screen. They come from real history: what was downloaded or copied here, and what was played here.
enum HomeListKind: String, CaseIterable, Hashable, Identifiable {
    case recentlyDownloaded, recentlyPlayed, mostPlayed

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .recentlyDownloaded: "Recently Downloaded"
        case .recentlyPlayed: "Recently Played"
        case .mostPlayed: "Most Played"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyDownloaded: "arrow.down.circle.fill"
        case .recentlyPlayed: "clock.fill"
        case .mostPlayed: "flame.fill"
        }
    }

    var emptyText: LocalizedStringKey {
        switch self {
        case .recentlyDownloaded: "Songs copied from your other device, downloaded from a link, or received from Telegram or another app show up here."
        case .recentlyPlayed: "Songs you play show up here."
        case .mostPlayed: "Your most played songs show up here after you have listened for a while."
        }
    }

    @MainActor
    func tracks(_ app: AppModel, limit: Int) -> [Track] {
        switch self {
        case .recentlyDownloaded: app.library.recentlyDownloaded(limit: limit)
        case .recentlyPlayed: app.stats.recentlyPlayed(in: app.library.tracks, limit: limit)
        case .mostPlayed: app.stats.mostPlayed(in: app.library.tracks, limit: limit)
        }
    }
}

/// A song as a card: cover, title, artist, and where it came from.
struct TrackCard: View {
    @Environment(AppModel.self) private var app
    let track: Track
    var width: CGFloat = Theme.cardWidth
    var showsSource = false
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: width, cornerRadius: 12)
                    .frame(width: width, height: width)
                    .overlay(alignment: .bottomTrailing) {
                        if app.playback.current?.id == track.id {
                            Image(systemName: app.playback.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(.white).padding(7)
                                .background(Theme.accent, in: .circle).padding(6)
                        }
                    }
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail ?? track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if showsSource, let file = track.file { SourceBadge(source: TrackSource(raw: file.source), showsLabel: true).lineLimit(1) }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.title), \(track.artist)")
        .accessibilityHint("Plays this song")
    }
}

/// A playlist as a card.
struct PlaylistCard: View {
    @Environment(AppModel.self) private var app
    let playlist: Playlist
    var width: CGFloat = Theme.cardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistCover(playlist: playlist).frame(width: width, height: width)
            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(app.playlists.summary(of: playlist)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
    }
}

struct NewPlaylistCard: View {
    var width: CGFloat = Theme.cardWidth
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                Image(systemName: "plus").font(.system(size: width * 0.28, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(width: width, height: width)
            Text("New Playlist").font(.subheadline.weight(.semibold))
            Text(" ").font(.caption)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
    }
}

/// A row title with an icon, used above each list on Home.
struct SectionHeader: View {
    let title: LocalizedStringKey
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(Theme.sectionTitle())
            .foregroundStyle(.primary)
            .labelStyle(HomeHeaderLabelStyle())
    }
}

private struct HomeHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.gradient)
            configuration.title
        }
    }
}

/// The scrolling content of Home, shared by both platforms. The container decides how a playlist or a "see all" opens.
struct HomeContent: View {
    @Environment(AppModel.self) private var app
    var cardWidth: CGFloat = Theme.cardWidth
    let openPlaylist: (Playlist) -> Void
    let newPlaylist: () -> Void
    var openList: ((HomeListKind) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            playlists
            ForEach(HomeListKind.allCases) { kind in section(kind) }
        }
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your Playlists", symbol: "music.note.list")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    Button(action: newPlaylist) { NewPlaylistCard(width: cardWidth) }.buttonStyle(.plain)
                    ForEach(app.playlists.playlists) { list in
                        Button { openPlaylist(list) } label: { PlaylistCard(playlist: list, width: cardWidth) }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { Task { await app.playlists.delete(list.id) } }
                            }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func section(_ kind: HomeListKind) -> some View {
        let tracks = kind.tracks(app, limit: 20)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: kind.title, symbol: kind.symbol)
                Spacer()
                if let openList, !tracks.isEmpty {
                    Button { openList(kind) } label: { Label("See All", systemImage: "chevron.right").labelStyle(.titleAndIcon).font(.subheadline) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if tracks.isEmpty {
                Text(kind.emptyText).font(.callout).foregroundStyle(.secondary).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading).cardBackground()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(tracks) { track in
                            TrackCard(track: track, width: cardWidth, showsSource: kind == .recentlyDownloaded,
                                      detail: kind == .mostPlayed ? detail(for: track) : nil) {
                                if let i = tracks.firstIndex(of: track) { app.play(tracks, startAt: i) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func detail(for track: Track) -> String {
        let n = app.stats.playCount(track.id)
        return "\(track.artist) · " + (n == 1 ? String(localized: "1 play") : String(localized: "\(n) plays"))
    }
}
