import Foundation
import Observation
import Domain
import Peering

/// Pairing state and live sync status for the screens. All networking is inside `SyncEngine`.
@MainActor
@Observable
public final class SyncModel {
    public private(set) var isPaired = false
    public private(set) var pairingCode: String?
    public private(set) var peers: [PeerInfo] = []
    public private(set) var status = String(localized: "Not paired")
    /// Download progress (0 to 1) for songs being fetched from another device.
    public private(set) var downloads: [LibraryFileID: Double] = [:]
    public private(set) var problem: String?
    public private(set) var joinError: String?

    @ObservationIgnored private let pairing: any PairingStore
    @ObservationIgnored private let networking: Bool
    @ObservationIgnored private let makeEngine: @MainActor (PairingKey) -> SyncEngine
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Called when the library or the set of local files changed because of a peer.
    @ObservationIgnored public var onRemoteChange: (@MainActor () -> Void)?
    @ObservationIgnored public var onArtworkReceived: (@MainActor () -> Void)?

    /// `networking: false` keeps pairing logic testable without opening ports or announcing on the network.
    public init(pairing: any PairingStore, networking: Bool = true, makeEngine: @escaping @MainActor (PairingKey) -> SyncEngine) {
        self.pairing = pairing
        self.networking = networking
        self.makeEngine = makeEngine
    }

    /// Resumes syncing at launch if this device was paired before.
    public func start() async {
        guard engine == nil, let key = pairing.load() else { return }
        await run(key)
    }

    /// Makes a new secret and returns it as a code to give to the other device.
    @discardableResult
    public func createPairing() async -> String {
        let key = PairingKey.generate()
        pairing.save(key)
        await run(key)
        return key.code
    }

    /// Joins the pairing started on another device.
    @discardableResult
    public func join(code: String) async -> Bool {
        guard let key = PairingKey(scanned: code) else {
            joinError = String(localized: "That code is not valid. It should be 64 letters and digits, shown in groups of 8.")
            return false
        }
        joinError = nil
        pairing.save(key)
        await run(key)
        return true
    }

    public func unpair() async {
        await engine?.stop()
        engine = nil
        listener?.cancel()
        pairing.clear()
        isPaired = false
        pairingCode = nil
        peers = []
        downloads = [:]
        status = String(localized: "Not paired")
    }

    public func libraryChanged() {
        guard let engine else { return }
        Task { await engine.localLibraryChanged() }
    }

    public func fetchFile(_ id: LibraryFileID) async throws {
        guard let engine else { throw PeeringError.noPeer }
        try await engine.fetchFile(id)
    }

    // MARK: Internals

    private func run(_ key: PairingKey) async {
        await engine?.stop()
        listener?.cancel()
        let engine = makeEngine(key)
        self.engine = engine
        isPaired = true
        pairingCode = key.code
        problem = nil
        status = String(localized: "Looking for your other device…")
        guard networking else { return }
        do {
            try await engine.startListening()
            try await engine.startDiscovery()
        } catch {
            problem = String(localized: "Could not start syncing: \(error.localizedDescription)")
        }
        listener = Task { [weak self] in
            for await event in engine.events { await self?.handle(event, from: engine) }
        }
    }

    private func handle(_ event: SyncEvent, from engine: SyncEngine) async {
        switch event {
        case .peerConnected(let name):
            defer { onRemoteChange?() }
            peers = await engine.peers
            status = String(localized: "Connected to \(name)")
            problem = nil
        case .peerDisconnected:
            peers = await engine.peers
            status = peers.isEmpty ? String(localized: "Looking for your other device…") : String(localized: "Connected to \(peers[0].name)")
        case .recordsReceived:
            onRemoteChange?()
        case .upToDate:
            if let first = peers.first { status = String(localized: "Up to date with \(first.name)") }
        case .fileProgress(let id, let received, let total):
            downloads[id] = total > 0 ? Double(received) / Double(total) : 0
        case .fileReceived(let id):
            downloads[id] = nil
            onRemoteChange?()
        case .artworkReceived:
            onArtworkReceived?()
        case .problem(let message):
            problem = message
        }
    }
}
