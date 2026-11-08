#if os(macOS)
import SwiftUI

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Add your music")
                .font(.title2.weight(.semibold))
            Text("Choose files or a folder, or drop them anywhere in this window. Songs stay where they are; Musicam remembers where.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Add Music…", systemImage: "plus", action: addMusic)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addMusic() {
        app.showImporter = true
    }
}
#endif
