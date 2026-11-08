#if os(macOS)
import SwiftUI
import Domain

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var name = ""
    @State private var query = ""

    var body: some View {
        let library = app.library
        Group {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else if library.isLoaded && library.tracks.isEmpty {
                EmptyLibraryView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(summary(count: library.tracks.count, seconds: library.totalDuration)).foregroundStyle(.secondary)
                        HomeContent(cardWidth: 168,
                                    openPlaylist: { app.section = .playlist($0.id) },
                                    newPlaylist: { name = ""; creating = true })
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(alignment: .top) {
                    LinearGradient(colors: [Theme.accent.opacity(0.18), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
                }
            }
        }
        .navigationTitle("Home")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Songs")
        .onChange(of: query) { _, _ in app.online.clear() }
        .toolbar { AddMusicToolbarItem() }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") { let n = name; Task { if let made = await app.playlists.create(name: n) { app.section = .playlist(made.id) } } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var searchResults: some View {
        let results = app.library.search(query)
        return List {
            if results.isEmpty {
                Text("No songs match “\(query)”.").foregroundStyle(.secondary)
            } else {
                Section("Songs") {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, track in
                        Button { app.play(results, startAt: i) } label: {
                            HStack {
                                TitleCell(track: track)
                                Spacer()
                                Text(track.artist).foregroundStyle(.secondary)
                                Text(formatTime(track.duration)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            OnlineSearchSection(query: query.trimmingCharacters(in: .whitespaces))
        }
    }

    private func summary(count: Int, seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        let length = hours >= 1 ? String(localized: "\(String(format: "%.1f", hours)) hours") : String(localized: "\(Int(seconds / 60)) minutes")
        return String(localized: "\(count) songs") + " · " + length
    }
}
#endif
