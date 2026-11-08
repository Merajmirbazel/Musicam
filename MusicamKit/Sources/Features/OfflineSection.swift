import SwiftUI
import Domain

/// Choose which songs this device keeps downloaded, and how much space they may use.
struct OfflineSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var offline = app.offline
        Section {
            Toggle(isOn: $offline.settings.enabled) { Label("Keep songs on this device", systemImage: "arrow.down.circle.fill") }
            if offline.settings.enabled {
                Toggle(isOn: $offline.settings.keepFavorites) { Label("Favorites", systemImage: "heart.fill") }
                ForEach(app.playlists.playlists) { list in
                    Toggle(isOn: playlistBinding(list.id)) { Label(list.name, systemImage: "folder.fill") }
                }
                Picker("Space limit", selection: $offline.settings.limitMegabytes) {
                    Text("No limit").tag(0)
                    Text("2 GB").tag(2_000)
                    Text("5 GB").tag(5_000)
                    Text("10 GB").tag(10_000)
                    Text("20 GB").tag(20_000)
                }
                Label(statusText(offline), systemImage: offline.state == .waiting ? "clock" : "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Offline")
        } footer: {
            Text("Chosen songs are copied here whenever your other device is reachable, so they play without it. With a limit, songs copied from your other device that you did not choose are removed, oldest first. Songs you imported on this device are never removed.")
        }
    }

    private func statusText(_ offline: OfflineModel) -> String {
        switch offline.state {
        case .off: String(localized: "Off")
        case .idle: String(localized: "Everything chosen is on this device")
        case .waiting: String(localized: "Waiting for your other device")
        case .working(let done, let total): String(localized: "Copying \(done + 1) of \(total)…")
        }
    }

    private func playlistBinding(_ id: PlaylistID) -> Binding<Bool> {
        Binding(get: { app.offline.settings.playlists.contains(id) },
                set: { on in
                    if on { app.offline.settings.playlists.insert(id) } else { app.offline.settings.playlists.remove(id) }
                })
    }
}
