import SwiftUI
import Domain
import Metadata

/// Opens Google, YouTube or Spotify in the browser, already searching for this song, so the person can check details by hand.
struct WebSearchMenu: View {
    let title: String
    let artist: String

    var body: some View {
        Menu {
            ForEach(WebSearchLinks.links(title: title, artist: artist)) { link in
                Link(destination: link.url) { Text(verbatim: link.name) }
            }
        } label: {
            Label("Search the Web", systemImage: "magnifyingglass")
        }
    }
}

/// Songs that still lack details and have no suggestion: each can be looked up on the web.
struct MissingDetailsSection: View {
    let tracks: [Track]

    var body: some View {
        if !tracks.isEmpty {
            Section {
                ForEach(tracks) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).lineLimit(1)
                            Text(t.artist.isEmpty ? String(localized: "No artist") : t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        WebSearchMenu(title: t.title, artist: t.artist).labelStyle(.iconOnly)
                    }
                }
            } header: {
                Text("Still missing details (\(tracks.count))")
            } footer: {
                Text("Opens a Google, YouTube or Spotify search in your browser so you can check the song, then edit it in Musicam.")
            }
        }
    }
}
