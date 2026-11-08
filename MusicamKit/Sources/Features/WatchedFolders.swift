#if os(macOS)
import Foundation
import Observation
import Domain
import Persistence
import Importing

/// Folders the Mac keeps an eye on: any song that appears in one is imported automatically.
/// Access is kept through security-scoped bookmarks, so it survives relaunch inside the sandbox.
@MainActor
@Observable
public final class WatchedFolders {
    public struct Entry: Identifiable, Equatable {
        public var id: String { path }
        public var path: String
        /// False when the folder cannot be reached (moved, deleted, drive not connected).
        public var isAvailable: Bool
    }

    public private(set) var entries: [Entry] = []

    @ObservationIgnored private let device: DeviceStore
    @ObservationIgnored private let importURLs: @MainActor ([URL], String) -> Void
    @ObservationIgnored private var active: [String: (url: URL, watcher: FolderWatcher)] = [:]

    public init(device: DeviceStore, importURLs: @escaping @MainActor ([URL], String) -> Void) {
        self.device = device
        self.importURLs = importURLs
    }

    /// Resumes watching the saved folders and picks up anything that arrived while the app was closed.
    public func start() async {
        let saved = (try? await device.watchedFolders()) ?? []
        for folder in saved { open(folder) }
        refreshEntries(saved)
    }

    /// Starts watching a folder the person just chose. Call with the URL from the folder picker.
    public func add(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: FileBookmarks.creation) else { return }
        let folder = WatchedFolder(path: url.path, bookmark: bookmark)
        try? await device.addWatchedFolder(folder)
        open(folder)
        refreshEntries((try? await device.watchedFolders()) ?? [folder])
    }

    public func remove(path: String) async {
        if let item = active.removeValue(forKey: path) {
            item.watcher.stop()
            item.url.stopAccessingSecurityScopedResource()
        }
        try? await device.removeWatchedFolder(path: path)
        refreshEntries((try? await device.watchedFolders()) ?? [])
    }

    // MARK: Internals

    private func open(_ folder: WatchedFolder) {
        guard active[folder.path] == nil else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: FileBookmarks.resolution, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else { url.stopAccessingSecurityScopedResource(); return }
        let watcher = FolderWatcher(folder: url) { [weak self] in
            let source = TrackSource.forWatchedFolder(path: folder.path).raw
            Task { @MainActor in self?.importURLs([url], source) }
        }
        guard watcher.start() else { url.stopAccessingSecurityScopedResource(); return }
        active[folder.path] = (url, watcher)
        importURLs([url], TrackSource.forWatchedFolder(path: folder.path).raw)   // catch up on anything added while we were not looking
    }

    private func refreshEntries(_ saved: [WatchedFolder]) {
        entries = saved.map { Entry(path: $0.path, isAvailable: active[$0.path] != nil) }
    }
}
#endif
