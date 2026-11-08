#if os(macOS)
import SwiftUI

/// Shows the selected section, with the import progress banner above it.
struct DetailContainer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.section {
            case .songs: SongsView()
            case .nowPlaying: NowPlayingView()
            case .devices: SyncSettingsView()
            case .folders: WatchedFoldersView()
            case .repair: RepairCenterView()
            case .wishlist: WishlistView()
            case .favorites: MacTrackTable(title: String(localized: "Favorites"), tracks: app.playlists.favorites)
            case .playlist(let id): MacPlaylistScreen(id: id)
            case .home, nil: HomeView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                NoticeBanner()
                ImportBanner()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UndoBanner().padding(.bottom, 8) }
    }
}
#endif
