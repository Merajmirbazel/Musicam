#if os(macOS)
import SwiftUI
import Domain

/// Right-hand panel: edit one song, or explain what is selected.
struct TrackInspectorView: View {
    @Environment(AppModel.self) private var app
    let selection: Set<Track.ID>

    var body: some View {
        if selection.count == 1, let id = selection.first, let track = app.library.track(id: id) {
            TrackEditor(track: track)
                .id(track.id)
        } else if selection.isEmpty {
            ContentUnavailableView("No Selection", systemImage: "music.note", description: Text("Select a song to see and edit its details."))
        } else {
            ContentUnavailableView("\(selection.count) songs selected", systemImage: "music.note.list")
        }
    }
}
#endif
