#if os(macOS)
import SwiftUI
import Domain

/// Edits the tags of one song. Changes are saved when you press Return or move to another field.
struct TrackEditor: View {
    @Environment(AppModel.self) private var app
    let track: Track
    @State private var draft: Draft
    @FocusState private var focused: Field?

    private enum Field: Hashable { case title, artist, album, albumArtist, genre }

    private struct Draft: Equatable {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var genre: String
        init(_ t: Track) { title = t.title; artist = t.artist; album = t.album; albumArtist = t.albumArtist; genre = t.genre }
    }

    init(track: Track) {
        self.track = track
        _draft = State(initialValue: Draft(track))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ArtworkView(key: track.artworkKey, seed: track.id, maxPoints: 260, cornerRadius: 12)
                    .frame(maxWidth: .infinity)
                field("Title", text: $draft.title, field: .title)
                field("Artist", text: $draft.artist, field: .artist)
                field("Album", text: $draft.album, field: .album)
                field("Album Artist", text: $draft.albumArtist, field: .albumArtist)
                field("Genre", text: $draft.genre, field: .genre)
                HStack {
                    RatingView(rating: track.rating, onChange: setRating)
                    Spacer()
                    Button(track.isFavorite ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites"),
                           systemImage: track.isFavorite ? "heart.fill" : "heart", action: toggleFavourite)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(track.isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Divider()
                FileInfoView(track: track, isStoredHere: app.library.isStoredHere(track))
            }
            .padding(16)
        }
        .onChange(of: focused) { old, _ in
            if old != nil { commit() }
        }
        .onDisappear(perform: commit)
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: field)
                .onSubmit(commit)
                .labelsHidden()
        }
    }

    private func commit() {
        var edit = TrackEdit()
        if draft.title != track.title, !draft.title.isEmpty { edit.title = draft.title }
        if draft.artist != track.artist { edit.artist = draft.artist }
        if draft.album != track.album { edit.album = draft.album }
        if draft.albumArtist != track.albumArtist { edit.albumArtist = draft.albumArtist }
        if draft.genre != track.genre { edit.genre = draft.genre }
        guard edit != TrackEdit() else { return }
        let id = track.id
        Task { await app.library.edit(id, edit) }
    }

    private func setRating(_ value: Int) {
        let id = track.id
        Task { await app.library.edit(id, TrackEdit(rating: value)) }
    }

    private func toggleFavourite() {
        let id = track.id, value = !track.isFavorite
        Task { await app.library.edit(id, TrackEdit(isFavorite: value)) }
    }
}
#endif
