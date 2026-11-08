#if os(macOS)
import SwiftUI
import Domain

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var renaming: Playlist?
    @State private var draftName = ""

    var body: some View {
        @Bindable var app = app
        List(selection: $app.section) {
            Section("Library") {
                Label("Home", systemImage: "house.fill").tag(AppSection.home)
                Label("Songs", systemImage: "music.note").badge(app.library.tracks.count).tag(AppSection.songs)
                Label("Favorites", systemImage: "heart.fill").tag(AppSection.favorites)
            }
            Section("Playlists") {
                ForEach(app.playlists.playlists) { list in
                    Label(list.name, systemImage: "folder.fill")
                        .badge(list.trackIDs.count)
                        .tag(AppSection.playlist(list.id))
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") { renaming = list; draftName = list.name }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                if app.section == .playlist(list.id) { app.section = .home }
                                Task { await app.playlists.delete(list.id) }
                            }
                        }
                }
                Button("New Playlist", systemImage: "folder.badge.plus") { creating = true; draftName = "" }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Section("More") {
                Label("Downloads", systemImage: "arrow.down.circle").badge(app.acquisition.activeCount).tag(AppSection.wishlist)
                Label("Repair Center", systemImage: "wand.and.stars").badge(app.repair.proposals.count).tag(AppSection.repair)
                Label("Watched Folders", systemImage: "folder.badge.gearshape").badge(app.watched.entries.count).tag(AppSection.folders)
                Label("Devices", systemImage: "arrow.triangle.2.circlepath").badge(app.sync.peers.count).tag(AppSection.devices)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .navigationTitle("Musicam")
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $draftName)
            Button("Create") {
                let name = draftName
                Task { if let made = await app.playlists.create(name: name) { app.section = .playlist(made.id) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let id = renaming?.id { let name = draftName; Task { await app.playlists.rename(id, to: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
#endif
