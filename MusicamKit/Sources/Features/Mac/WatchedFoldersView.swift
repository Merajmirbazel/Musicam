#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Choose folders that Musicam checks for new songs, for example the folder where Telegram saves downloads.
struct WatchedFoldersView: View {
    @Environment(AppModel.self) private var app
    @State private var choosing = false

    var body: some View {
        let entries = app.watched.entries
        Form {
            Section("Watched folders") {
                if entries.isEmpty {
                    Text("No folders yet. Songs that appear in a watched folder are added to your library by themselves.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    WatchedFolderRow(entry: entry)
                }
                Button("Add Folder…", systemImage: "plus", action: chooseFolder)
                Button("Add Telegram Folder…", systemImage: "paperplane.fill", action: chooseTelegramFolder)
            }
            Section("Tip") {
                Text("Telegram Desktop usually saves files in a folder called “Telegram Desktop” inside Downloads. Watch that folder and every audio file you receive shows up in Musicam, then on your iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Watched Folders")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], onCompletion: folderChosen)
    }

    /// Opens the folder picker at Telegram Desktop's usual download folder. Files that appear there are marked "Telegram".
    private func chooseTelegramFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Watch This Folder")
        panel.message = String(localized: "Choose the folder where Telegram Desktop saves your downloads.")
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            let downloads = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads")
            let telegram = downloads.appendingPathComponent("Telegram Desktop")
            panel.directoryURL = FileManager.default.fileExists(atPath: telegram.path) ? telegram : downloads
        }
        if panel.runModal() == .OK, let url = panel.url { Task { await app.watched.add(url) } }
    }

    private func chooseFolder() {
        choosing = true
    }

    private func folderChosen(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task { await app.watched.add(url) }
    }
}
#endif
