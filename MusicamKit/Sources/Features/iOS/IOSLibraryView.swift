#if os(iOS)
import SwiftUI
import Domain

/// Everything you own: all songs, favorites, and playlists (which work like folders).
struct IOSLibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = Tab.songs
    @State private var creating = false
    @State private var name = ""
    @State private var renaming: Playlist?
    @State private var path: [AppSection] = []

    enum Tab: String, CaseIterable, Identifiable {
        case songs, playlists, favorites
        var id: String { rawValue }
        var title: LocalizedStringKey { switch self { case .songs: "Songs"; case .playlists: "Playlists"; case .favorites: "Favorites" } }
        var symbol: String { switch self { case .songs: "music.note"; case .playlists: "music.note.list"; case .favorites: "heart.fill" } }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.spacing).padding(.vertical, 8)
                switch tab {
                case .songs:
                    IOSSongList(tracks: app.library.tracks.sorted { $0.addedAt > $1.addedAt })
                        .overlay { if app.library.isLoaded && app.library.tracks.isEmpty { IOSEmptyLibrary() } }
                case .favorites:
                    IOSSongList(tracks: app.playlists.favorites)
                        .overlay { if app.playlists.favorites.isEmpty { ContentUnavailableView("No favorites yet", systemImage: "heart", description: Text("Swipe a song to the right to add it.")) } }
                case .playlists:
                    playlists
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Add Music", systemImage: "plus.circle.fill") {
                        Button("Add Music", systemImage: "folder.badge.plus") { app.showImporter = true }
                        Button("Add from Link…", systemImage: "link.badge.plus") { app.showLinkSheet = true }
                    }
                }
                if tab == .playlists {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Playlist", systemImage: "folder.badge.plus") { name = ""; creating = true }
                    }
                }
            }
            .navigationDestination(for: AppSection.self) { iosDestination($0) }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $name)
                Button("Create") { let n = name; Task { await app.playlists.create(name: n) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Rename") { if let id = renaming?.id { let n = name; Task { await app.playlists.rename(id, to: n) } } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var playlists: some View {
        List {
            ForEach(app.playlists.playlists) { list in
                NavigationLink(value: AppSection.playlist(list.id)) {
                    HStack(spacing: 12) {
                        PlaylistCover(playlist: list, cornerRadius: 8).frame(width: 56, height: 56)
                        VStack(alignment: .leading) {
                            Text(list.name).font(.body.weight(.semibold))
                            Text(app.playlists.summary(of: list)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await app.playlists.delete(list.id) } }
                }
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") { name = list.name; renaming = list }
                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await app.playlists.delete(list.id) } }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if app.playlists.playlists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists yet", systemImage: "music.note.list")
                } description: {
                    Text("Playlists work like folders: make one, then add songs from the Songs list.")
                } actions: {
                    Button("New Playlist", systemImage: "folder.badge.plus") { name = ""; creating = true }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct IOSPlaylistDetail: View {
    @Environment(AppModel.self) private var app
    let id: PlaylistID

    var body: some View {
        if let list = app.playlists.playlist(id: id) {
            let tracks = app.playlists.tracks(of: list)
            IOSSongList(tracks: tracks, playlist: list)
                .navigationTitle(list.name)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Shuffle", systemImage: "shuffle") { if !tracks.isEmpty { app.play(tracks.shuffled(), startAt: 0) } }.disabled(tracks.isEmpty)
                    }
                }
                .overlay {
                    if tracks.isEmpty {
                        ContentUnavailableView("Empty Playlist", systemImage: "music.note.list", description: Text("Touch and hold a song in Library and choose Add to Playlist."))
                    }
                }
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "questionmark.folder")
        }
    }
}

struct IOSFavoritesView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        IOSSongList(tracks: app.playlists.favorites).navigationTitle("Favorites")
    }
}
#endif
