#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import Domain

/// The iPhone and iPad main screen: Home, Search, Library and More, with the player above the tab bar.
public struct IOSRootView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var app = app
        TabView {
            Tab("Home", systemImage: "house.fill") { IOSHomeView().miniPlayerInset() }
            Tab("Library", systemImage: "books.vertical.fill") { IOSLibraryView().miniPlayerInset() }
            Tab("More", systemImage: "ellipsis.circle.fill") { IOSMoreView().miniPlayerInset() }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $app.showLinkSheet) { AddLinkSheet() }
        .fileImporter(isPresented: $app.showImporter, allowedContentTypes: [.audio, .folder],
                      allowsMultipleSelection: true, onCompletion: app.importerFinished)
        .appLock()
        .task { await app.start() }
    }
}

/// Where a navigation value leads, so every tab opens the same screens.
@MainActor @ViewBuilder
func iosDestination(_ section: AppSection) -> some View {
    switch section {
    case .playlist(let id): IOSPlaylistDetail(id: id)
    case .favorites: IOSFavoritesView()
    case .wishlist: WishlistView()
    case .repair: IOSRepairView()
    case .devices: SyncSettingsView()
    default: EmptyView()
    }
}

struct IOSHomeListView: View {
    @Environment(AppModel.self) private var app
    let kind: HomeListKind

    var body: some View {
        IOSSongList(tracks: kind.tracks(app, limit: 500), showsPlayCount: kind == .mostPlayed)
            .navigationTitle(Text(kind.title))
            .overlay { if kind.tracks(app, limit: 1).isEmpty { ContentUnavailableView { Label(kind.title, systemImage: kind.symbol) } description: { Text(kind.emptyText) } } }
    }
}

extension View {
    /// Puts the Undo strip and the mini player above the tab bar on this screen.
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
}

private struct MiniPlayerInset: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                UndoBanner()
                // while songs are being selected the action bar needs this space
                if !app.isSelectingSongs { MiniPlayerView() }
            }
            .animation(.spring(duration: 0.3), value: app.isSelectingSongs)
        }
    }
}
#endif
