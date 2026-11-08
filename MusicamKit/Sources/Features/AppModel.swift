import Foundation
import Observation
import Domain
import Persistence
import Importing
import Playback
import Peering
import Metadata
import Acquisition
#if os(iOS)
import UIKit
#endif

/// The app's object graph, created once at launch and handed to the views through the environment.
@MainActor
@Observable
public final class AppModel {
    public let library: LibraryModel
    public let playback: PlaybackService
    public let sync: SyncModel
    public let repair: RepairModel
    public let playlists: PlaylistModel
    public let offline: OfflineModel
    public let wishlist: WishlistModel
    public let stats: StatsModel
    public let online: OnlineSearchModel
    public let acquisition: AcquisitionManager
    public let merajfy: MerajfySettings
    public let undo: UndoCenter
    @ObservationIgnored let deviceForCleanup: DeviceStore
    public let lock: AppLockModel
    #if os(macOS)
    public let watched: WatchedFolders
    #endif
    public let artwork: ArtworkImageCache
    public let artworkStore: ArtworkStore
    public var section: AppSection? = .home
    public var showImporter = false
    public var showLinkSheet = false
    /// True while a song list is in Select mode on iOS; the mini player steps aside so it never covers the action bar.
    public var isSelectingSongs = false
    /// A link handed over by the share extension; the Add from Link sheet picks it up and adds it.
    public var pendingLink: String?
    /// Selection in the Songs table; kept here so it survives switching sections.
    public var songSelection = Set<TrackID>()

    private static let volumeKey = "musicam.volume"

    public init(libraryStore: LibraryStore, deviceStore: DeviceStore, artworkStore: ArtworkStore,
                engine: any PlaybackEngine, nowPlaying: (any NowPlayingPublishing)?,
                pairing: any PairingStore, deviceName: String, mediaDirectory: URL) {
        self.deviceForCleanup = deviceStore
        let importer = ImportService(library: libraryStore, device: deviceStore, artwork: artworkStore)
        let appFolder = mediaDirectory.deletingLastPathComponent()
        let library = LibraryModel(store: libraryStore, device: deviceStore, importer: importer, appFolder: appFolder, mediaDirectory: mediaDirectory)
        let undo = UndoCenter()
        library.undo = undo
        self.undo = undo
        self.lock = AppLockModel()
        let stats = StatsModel(device: deviceStore)
        self.stats = stats
        let sync = SyncModel(pairing: pairing) { key in
            SyncEngine(library: libraryStore, device: deviceStore, key: key, deviceName: deviceName, mediaDirectory: mediaDirectory, artwork: artworkStore)
        }
        self.library = library
        self.sync = sync
        let playlists = PlaylistModel(store: libraryStore, library: library)
        self.playlists = playlists
        playlists.undo = undo
        let offline = OfflineModel(library: library, playlists: playlists, device: deviceStore, mediaDirectory: mediaDirectory,
                                    fetch: { id in try await sync.fetchFile(id) },
                                    isConnected: { !sync.peers.isEmpty })
        self.offline = offline
        // Getting files goes through one manager; whatever it fetches is imported by the same path as picked files.
        let downloads = appFolder.appendingPathComponent("Downloaded", isDirectory: true)
        let merajfy = MerajfySettings()
        self.merajfy = merajfy
        let acquisition = AcquisitionManager(registry: .standard(downloadsDirectory: downloads, merajfy: merajfy.store, onDevice: merajfy.onDevice), handoff: { [weak library] files in
            await MainActor.run {
                for (source, urls) in AcquiredFile.grouped(files) { library?.startImport(urls, source: source) }
            }
        })
        self.acquisition = acquisition
        let wishlist = WishlistModel(store: WishlistStore(url: appFolder.appendingPathComponent("wishlist.json")),
                                      fetcher: OEmbedClient(),
                                      downloader: DirectAudioDownloader(directory: downloads),
                                      importFiles: { [weak library] urls, source in library?.startImport(urls, source: source) },
                                      acquisition: acquisition)
        self.wishlist = wishlist
        self.online = OnlineSearchModel(download: { url in await wishlist.submit(url.absoluteString) })
        // online details come from the public Deezer and Apple Music search (no account needed)
        self.repair = RepairModel(library: library, historyURL: mediaDirectory.deletingLastPathComponent().appendingPathComponent("repairs.json"),
                                  lookup: CompositeLookup.web(), artworkStore: artworkStore,
                                  cover: { ref in
                                      if ref.hasPrefix("http"), let url = URL(string: ref) { return await CoverArtClient().image(at: url) }
                                      return await CoverArtClient().frontCover(releaseID: ref)
                                  })
        #if os(macOS)
        self.watched = WatchedFolders(device: deviceStore) { [weak library] urls, source in library?.startImport(urls, source: source) }
        #endif
        self.artworkStore = artworkStore
        self.artwork = ArtworkImageCache(store: artworkStore)
        let files = OnDemandFileAccess(local: FileAccessService(device: deviceStore)) { id in try await sync.fetchFile(id) }
        self.playback = PlaybackService(engine: engine, files: files, nowPlaying: nowPlaying,
                                        artwork: { key in artworkStore.data(for: key) })
        library.onLocalChange = { [weak sync] in sync?.libraryChanged() }
        playlists.onLocalChange = { [weak sync] in sync?.libraryChanged() }
        sync.onArtworkReceived = { [weak artwork = self.artwork] in artwork?.coversArrived() }
        sync.onRemoteChange = { [weak library] in
            guard let library else { return }
            Task { await library.mergeDuplicates(); await library.load(); await playlists.load(); await offline.reconcile() }
        }
        repair.undoCenter = undo
        playback.onPlayed = { track in Task { await stats.recordPlay(track.id) } }
        if let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double {
            playback.volume = Float(min(max(saved, 0), 1))
        }
    }

    /// The real library, kept in the app's own Application Support folder (inside the sandbox container on macOS).
    public static func live() throws -> AppModel {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Musicam", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(macOS)
        let pairing: any PairingStore = FilePairingStore(url: dir.appendingPathComponent("pairing.key"))
        let name = Host.current().localizedName ?? "Mac"
        #else
        let pairing: any PairingStore = KeychainPairingStore()
        let name = UIDevice.current.name
        #endif
        return AppModel(
            libraryStore: try LibraryStore.open(at: dir.appendingPathComponent("library.store")),
            deviceStore: try DeviceStore.open(at: dir.appendingPathComponent("device.store")),
            artworkStore: ArtworkStore(directory: dir.appendingPathComponent("Artwork", isDirectory: true)),
            engine: AVQueuePlayerEngine(),
            nowPlaying: SystemNowPlaying(),
            pairing: pairing, deviceName: name,
            mediaDirectory: dir.appendingPathComponent("Media", isDirectory: true))
    }

    /// Everything in memory and a throw-away artwork folder: for tests and previews.
    public static func inMemory(engine: any PlaybackEngine) throws -> AppModel {
        let art = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-art-\(UUID().uuidString)")
        return AppModel(libraryStore: try LibraryStore.open(at: nil), deviceStore: try DeviceStore.open(at: nil),
                        artworkStore: ArtworkStore(directory: art), engine: engine, nowPlaying: nil,
                        pairing: MemoryPairingStore(), deviceName: "Test device",
                        mediaDirectory: art.appendingPathComponent("media"))
    }

    // MARK: Actions the views call

    /// Loads the library and resumes syncing with a paired device. Call once when the window appears.
    public func start() async {
        await library.load()
        await playlists.load()
        await wishlist.load()
        await library.sweepOrphanedCopies()
        await stats.load()
        await sync.start()
        await offline.reconcile()
        #if os(macOS)
        await watched.start()
        #endif
    }

    public func importerFinished(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result { importPicked(urls) }
    }

    /// On the Mac songs are used where they are. On iOS the app cannot keep access to files it was shown,
    /// so picked files are copied into the app's own storage first.
    /// `source` records where the files came from (nil: picked by hand; "shared" for files other apps hand over).
    public func importPicked(_ urls: [URL], source: String? = nil) {
        #if os(iOS)
        let fromFolder = urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        Task {
            let copies = await Self.copyIntoApp(urls)
            library.startImport(copies, source: source ?? (fromFolder ? TrackSource.folder.raw : nil)) { [device = self.deviceForCleanup] in
                await Self.removeUnusedCopies(copies, device: device)
            }
        }
        #else
        library.startImport(urls, source: source)
        #endif
    }

    #if os(iOS)
    /// Copies made for files that turned out to be in the library already would only waste space: remove them.
    private static func removeUnusedCopies(_ copies: [URL], device: DeviceStore) async {
        let known = (try? await device.knownFilesByPath()) ?? [:]
        for copy in copies where known[copy.path] == nil {
            try? FileManager.default.removeItem(at: copy)
            let folder = copy.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private static func copyIntoApp(_ urls: [URL]) async -> [URL] {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return [] }
        let target = support.appendingPathComponent("Musicam/Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var copies: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            for file in AudioFileScanner.audioFiles(in: [url]) {
                // a folder of its own keeps the original file name (it is used as the title when a song has no tags)
                let folder = target.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let destination = folder.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(at: file, to: destination)) != nil { copies.append(destination) }
            }
            // files other apps hand over land in our own Inbox folder; once copied, the original is not needed
            if url.pathComponents.contains("Inbox") || url.pathComponents.contains("Downloaded"), url.isFileURL { try? FileManager.default.removeItem(at: url) }
        }
        return copies
    }
    #endif

    @discardableResult
    public func handleDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        importPicked(urls)
        return true
    }

    public func rememberVolume() {
        UserDefaults.standard.set(Double(playback.volume), forKey: Self.volumeKey)
    }

    public func play(_ tracks: [Track], startAt index: Int) {
        playback.play(tracks, startAt: index)
    }
}
