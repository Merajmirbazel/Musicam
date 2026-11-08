import Foundation
import Observation
import Domain
import Persistence

/// Keeps the songs the person asked for downloaded on this device, and frees space when a limit is set.
/// Only copies fetched from another device are ever removed; songs imported here are never touched.
@MainActor
@Observable
public final class OfflineModel {
    public enum State: Equatable {
        case off
        case idle
        case waiting                                // there is something to fetch but no other device is reachable
        case working(done: Int, total: Int)
    }

    public var settings: OfflineSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            Task { await reconcile() }
        }
    }
    public private(set) var state: State = .off
    public private(set) var freedBytes: Int64 = 0

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let playlists: PlaylistModel
    @ObservationIgnored private let device: DeviceStore
    @ObservationIgnored private let mediaDirectory: URL
    @ObservationIgnored private let store: OfflineSettingsStore
    @ObservationIgnored private let fetch: @MainActor (LibraryFileID) async throws -> Void
    @ObservationIgnored private let isConnected: @MainActor () -> Bool
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false

    public init(library: LibraryModel, playlists: PlaylistModel, device: DeviceStore, mediaDirectory: URL,
                store: OfflineSettingsStore = OfflineSettingsStore(),
                fetch: @escaping @MainActor (LibraryFileID) async throws -> Void,
                isConnected: @escaping @MainActor () -> Bool) {
        self.library = library
        self.playlists = playlists
        self.device = device
        self.mediaDirectory = mediaDirectory
        self.store = store
        self.fetch = fetch
        self.isConnected = isConnected
        self.settings = store.load()
        self.state = settings.enabled ? .idle : .off
    }

    /// Brings this device in line with the settings. Safe to call often: overlapping calls are folded into one more pass.
    public func reconcile() async {
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            await pass()
        } while again
    }

    private func pass() async {
        guard settings.enabled else { state = .off; return }
        let present = (try? await device.presentFileIDs()) ?? []
        let plan = OfflinePlanner.plan(settings: settings, tracks: library.tracks, playlists: playlists.playlists,
                                       present: present, fetched: await fetchedFiles())
        await evict(plan.toEvict)
        guard !plan.toDownload.isEmpty else { state = .idle; return }
        guard isConnected() else { state = .waiting; return }

        var done = 0
        for track in plan.toDownload {
            guard let file = track.file else { continue }
            state = .working(done: done, total: plan.toDownload.count)
            if again { break }                                  // settings changed: start over with the new plan
            do { try await fetch(file.id) } catch { state = .waiting; return }
            done += 1
        }
        await library.load()
        state = again ? .idle : (isConnected() ? .idle : .waiting)
    }

    private func fetchedFiles() async -> [FetchedFile] {
        let root = mediaDirectory.resolvingSymlinksInPath().path
        let entries = (try? await device.presentEntries()) ?? []
        return entries.compactMap { entry in
            let url = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root + "/") else { return nil }
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate]) as? Date ?? .distantPast
            return FetchedFile(id: entry.audioFileID, size: entry.byteSize, date: date)
        }
    }

    private func evict(_ ids: [LibraryFileID]) async {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let entry = try? await device.entry(for: id) else { continue }
            try? FileManager.default.removeItem(atPath: entry.path)
            try? await device.setState(.missing, for: id)
            freedBytes += entry.byteSize
        }
        await library.load()
    }
}
