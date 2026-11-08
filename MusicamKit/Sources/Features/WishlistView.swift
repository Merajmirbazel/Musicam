import SwiftUI
import Domain
import Metadata
import Acquisition

/// Downloads: what is being fetched right now (Spotify links through Merajfy, audio links), and the songs you only
/// remembered by name, ticked off when a matching song appears in your library.
struct WishlistView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        let tracks = app.library.tracks
        let jobs = app.acquisition.jobs.reversed().map { $0 }
        List {
            if !jobs.isEmpty {
                Section {
                    ForEach(jobs) { job in DownloadRow(job: job) }
                } header: {
                    HStack {
                        Text("Downloads")
                        Spacer()
                        if jobs.contains(where: { $0.state.isFinal }) {
                            Button("Clear Finished") { app.acquisition.clearFinished() }.font(.caption).textCase(nil)
                        }
                    }
                }
            }
            Section(app.wishlist.items.isEmpty ? "" : String(localized: "Wishlist")) {
            ForEach(app.wishlist.items) { wish in
                let found = app.wishlist.match(for: wish, in: tracks)
                HStack(spacing: 12) {
                    AsyncImage(url: wish.thumbnailURL) { $0.resizable().scaledToFill() } placeholder: {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                    .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6)).background(.quaternary, in: .rect(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(wish.title).lineLimit(1)
                        if !wish.artist.isEmpty { Text(wish.artist).foregroundStyle(.secondary).lineLimit(1) }
                        WishSourceBadge(url: wish.sourceURL)
                    }
                    Spacer()
                    if let found {
                        Button("Play", systemImage: "play.fill") { app.play([found], startAt: 0) }.labelStyle(.iconOnly)
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("In your library")
                    } else {
                        Link(destination: wish.sourceURL) { Label("Open", systemImage: "arrow.up.right.square") }.labelStyle(.iconOnly)
                    }
                }
                .swipeActionsCompat { Task { await app.wishlist.remove(wish.id) } }
                .contextMenu { Button("Remove from Wishlist", systemImage: "trash", role: .destructive) { Task { await app.wishlist.remove(wish.id) } } }
            }
            }
        }
        .overlay {
            if app.wishlist.items.isEmpty && jobs.isEmpty {
                ContentUnavailableView("No downloads yet", systemImage: "arrow.down.circle",
                                       description: Text("Paste a Spotify link in Add from Link and the song is downloaded into your library."))
            }
        }
        .navigationTitle("Downloads")
        .reservesPlayerSpace()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Add from Link…", systemImage: "link.badge.plus") { adding = true } }
        }
        .sheet(isPresented: $adding) { AddLinkSheet() }
        .task { await app.wishlist.load() }
    }
}

private extension View {
    @ViewBuilder func swipeActionsCompat(_ remove: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.swipeActions { Button("Delete", systemImage: "trash", role: .destructive, action: remove) }
        #else
        self
        #endif
    }
}

/// One download: its name, what it is doing, and the buttons that make sense for that state.
private struct DownloadRow: View {
    @Environment(AppModel.self) private var app
    let job: AcquisitionManager.Job

    private var title: String {
        if let t = job.request.titleHint, !t.isEmpty { return t }
        if let q = job.request.query, !q.isEmpty { return q }
        if let url = job.request.url { return url.host() ?? url.absoluteString }
        return String(localized: "Download")
    }

    var body: some View {
        let manager = app.acquisition
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                detail
            }
            Spacer()
            switch job.state {
            case .queued, .acquiring, .importing:
                Button("Cancel", systemImage: "xmark.circle") { manager.cancel(job.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            case .failed(let error) where error.isRetryable:
                Button("Try Again", systemImage: "arrow.clockwise") { manager.retry(job.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            case .cancelled:
                Button("Try Again", systemImage: "arrow.clockwise") { manager.retry(job.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        default: ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .queued: Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .acquiring:
            if let fraction = job.progress.fraction {
                ProgressView(value: fraction)
            }
            Text(job.progress.message ?? String(localized: "Downloading…")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .importing: Text("Adding to your library…").font(.caption).foregroundStyle(.secondary)
        case .finished(let files): Text("Songs added: \(files)").font(.caption).foregroundStyle(.secondary)
        case .failed(let error): Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }
}
