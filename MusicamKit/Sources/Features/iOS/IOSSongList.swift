#if os(iOS)
import SwiftUI
import Domain

/// A list of songs with everything a person expects on a phone: tap to play, swipe, touch and hold, and a Select mode for
/// choosing many songs and acting on them together. Inside a playlist, "Remove" takes songs out of the playlist only.
struct IOSSongList: View {
    @Environment(AppModel.self) private var app
    let tracks: [Track]
    var playlist: Playlist?
    var showsPlayCount = false
    /// Extra rows shown after the songs (for example the online search results on Home).
    var extra: AnyView?
    @State private var selection = Set<Track.ID>()
    @State private var editMode: EditMode = .inactive
    @State private var newPlaylistFor: [Track.ID]?
    @State private var newName = ""

    private var isSelecting: Bool { editMode == .active }

    var body: some View {
        // Toolbars and menus rebuild later on their own; they use this captured model, never the @Environment property.
        let model = app
        List(selection: $selection) {
            ForEach(tracks) { track in
                row(track, tracks: tracks, model: model)
                    .tag(track.id)
                    .swipeActions(edge: .leading) {
                        Button(track.isFavorite ? "Unfavorite" : "Favorite", systemImage: track.isFavorite ? "heart.slash" : "heart") { toggleFavorite([track], model) }
                            .tint(Theme.accent2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(playlist == nil ? "Remove" : "Remove from Playlist", systemImage: playlist == nil ? "trash" : "minus.circle", role: .destructive) { remove([track.id], model) }
                    }
                    .contextMenu { menu(for: [track], model) }
            }
            .onMove(perform: playlist == nil ? nil : { from, to in
                if let id = playlist?.id { Task { await model.playlists.move(in: id, from: from, to: to) } }
            })
            if let extra { extra }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Done" : "Select", systemImage: isSelecting ? "checkmark" : "checkmark.circle") {
                        withAnimation { editMode = isSelecting ? .inactive : .active }
                        if !isSelecting { selection = [] }
                    }
                }
            }
        }
        .alert("New Playlist", isPresented: Binding(get: { newPlaylistFor != nil }, set: { if !$0 { newPlaylistFor = nil } })) {
            TextField("Name", text: $newName)
            Button("Create") {
                let ids = newPlaylistFor ?? []; let name = newName
                Task { await model.playlists.create(name: name, tracks: ids) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: isSelecting) { _, now in model.isSelectingSongs = now }
        .onDisappear { model.isSelectingSongs = false }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                HStack(spacing: 18) { bulkBar(model) }
                    .labelStyle(.iconOnly).font(.title3)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: isSelecting)
    }

    /// Tap plays the song. While selecting, the row is left alone so a tap just ticks it.
    @ViewBuilder private func row(_ track: Track, tracks: [Track], model: AppModel) -> some View {
        if isSelecting {
            IOSTrackRow(track: track, showsPlayCount: showsPlayCount)
        } else {
            Button { if let i = tracks.firstIndex(of: track) { model.play(tracks, startAt: i) } } label: {
                IOSTrackRow(track: track, showsPlayCount: showsPlayCount)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Bulk actions

    @ViewBuilder private func bulkBar(_ app: AppModel) -> some View {
        let chosen = tracks.filter { selection.contains($0.id) }
        Button(selection.count == tracks.count ? "Deselect All" : "Select All", systemImage: selection.count == tracks.count ? "circle" : "checkmark.circle.fill") {
            selection = selection.count == tracks.count ? [] : Set(tracks.map(\.id))
        }
        Text("\(selection.count)").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
        Spacer()
        Menu("Add to Playlist", systemImage: "text.badge.plus") { addMenu(for: chosen.map(\.id), app) }
            .disabled(chosen.isEmpty)
        Button("Favorite", systemImage: "heart") { toggleFavorite(chosen, app) }.disabled(chosen.isEmpty)
        Button(playlist == nil ? "Remove" : "Remove from Playlist", systemImage: "trash", role: .destructive) {
            remove(Set(chosen.map(\.id)), app); selection = []; editMode = .inactive
        }
        .disabled(chosen.isEmpty)
    }

    @ViewBuilder private func menu(for chosen: [Track], _ app: AppModel) -> some View {
        Button("Play", systemImage: "play.fill") { if let i = tracks.firstIndex(of: chosen[0]) { app.play(tracks, startAt: i) } }
        Button("Play Next", systemImage: "text.insert") { chosen.reversed().forEach(app.playback.playNext) }
        Button("Add to Queue", systemImage: "text.append") { chosen.forEach(app.playback.addToQueue) }
        Menu("Add to Playlist", systemImage: "text.badge.plus") { addMenu(for: chosen.map(\.id), app) }
        Button(chosen.allSatisfy(\.isFavorite) ? "Unfavorite" : "Favorite", systemImage: "heart") { toggleFavorite(chosen, app) }
        Divider()
        Button(playlist == nil ? "Remove from Library" : "Remove from Playlist", systemImage: "trash", role: .destructive) { remove(Set(chosen.map(\.id)), app) }
    }

    @ViewBuilder private func addMenu(for ids: [Track.ID], _ app: AppModel) -> some View {
        ForEach(app.playlists.playlists) { list in
            Button(list.name, systemImage: "music.note.list") { Task { await app.playlists.add(ids, to: list.id) } }
        }
        Button("New Playlist…", systemImage: "plus") { newName = ""; newPlaylistFor = ids }
    }

    private func toggleFavorite(_ chosen: [Track], _ app: AppModel) {
        let make = !chosen.allSatisfy(\.isFavorite)
        Task { for t in chosen { await app.library.edit(t.id, TrackEdit(isFavorite: make)) } }
    }

    private func remove(_ ids: Set<Track.ID>, _ app: AppModel) {
        Task {
            if let playlist { await app.playlists.remove(ids, from: playlist.id) } else { await app.library.remove(ids) }
        }
    }
}
#endif
