#if os(iOS)
import SwiftUI
import Domain

/// Home: playlists, recent songs, and search. Typing in the search field replaces Home with matching songs
/// (found offline, in Persian, Arabic or English letters) and offers an online search for downloadable music.
struct IOSHomeView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [HomeRoute] = []
    @State private var creating = false
    @State private var name = ""
    @State private var query = ""

    enum HomeRoute: Hashable { case section(AppSection), list(HomeListKind), settings }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isSearching { searchResults } else { homeScroll }
            }
            .background(alignment: .top) {
                LinearGradient(colors: [Theme.accent.opacity(0.28), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
            }
            .navigationTitle(Text(greeting))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Song title, artist or album")
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape.fill") { path.append(.settings) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add Music", systemImage: "plus.circle.fill") {
                        Button("Add Music", systemImage: "folder.badge.plus") { app.showImporter = true }
                        Button("Add from Link…", systemImage: "link.badge.plus") { app.showLinkSheet = true }
                    }
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .section(let s): iosDestination(s)
                case .list(let kind): IOSHomeListView(kind: kind)
                case .settings: SettingsHost()
                }
            }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $name)
                Button("Create") { let n = name; Task { if let made = await app.playlists.create(name: n) { path.append(.section(.playlist(made.id))) } } }
                Button("Cancel", role: .cancel) {}
            }
            .refreshable { await app.library.load(); await app.stats.load() }
            .onChange(of: query) { _, _ in app.online.clear() }
        }
    }

    private var homeScroll: some View {
        ScrollView {
            if app.library.isLoaded && app.library.tracks.isEmpty {
                IOSEmptyLibrary().padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    syncChip
                    HomeContent(openPlaylist: { path.append(.section(.playlist($0.id))) },
                                newPlaylist: { name = ""; creating = true },
                                openList: { path.append(.list($0)) })
                }
                .padding(.horizontal, Theme.spacing)
                .padding(.vertical, 12)
            }
        }
    }

    private var searchResults: some View {
        let results = app.library.search(query)
        return IOSSongList(tracks: results, extra: AnyView(
            Group {
                if results.isEmpty {
                    Text("No songs match “\(query)”.").foregroundStyle(.secondary)
                }
                OnlineSearchSection(query: query.trimmingCharacters(in: .whitespaces))
            }
        ))
    }

    private var syncChip: some View {
        Label(app.sync.status, systemImage: app.sync.peers.isEmpty ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(app.sync.peers.isEmpty ? Color.secondary : Color.green)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
    }
}

/// Settings with the screens it links to.
struct SettingsHost: View {
    var body: some View {
        SettingsView()
    }
}
#endif
