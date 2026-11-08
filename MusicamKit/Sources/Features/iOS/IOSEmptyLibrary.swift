#if os(iOS)
import SwiftUI

struct IOSEmptyLibrary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("No songs yet", systemImage: "music.note.list")
        } description: {
            Text("Add songs from Files or share them from Telegram, or open More and pair with your Mac to bring your library here.")
        } actions: {
            Button("Add Music", systemImage: "plus", action: addMusic)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
    }

    private func addMusic() { app.showImporter = true }
}
#endif
