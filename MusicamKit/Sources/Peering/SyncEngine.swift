import Foundation
import Network
import CryptoKit
import Domain
import Sync
import Persistence
import Importing

/// Keeps this device's library identical to its paired devices' and moves audio files between them.
/// Everything runs over TLS authenticated by the pairing key; nothing leaves the local network.
public actor SyncEngine {
    public static let serviceType = "_musicam._tcp"
    static let protocolVersion = 2
    private static let batchSize = 500
    private static let chunkSize = 256 * 1024

    public nonisolated let events: AsyncStream<SyncEvent>
    private let continuation: AsyncStream<SyncEvent>.Continuation

    private let library: LibraryStore
    private let device: DeviceStore
    private let access: FileAccessService
    private let key: PairingKey
    private let deviceName: String
    private let mediaDirectory: URL
    private let artwork: ArtworkStore?
    /// Covers already asked for during this run, so one missing cover is not requested over and over.
    private var askedArtwork = Set<String>()

    private var myID: DeviceID?
    private var sessions: [DeviceID: Session] = [:]
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connecting: Set<DeviceID> = []
    private var incoming: [LibraryFileID: Incoming] = [:]
    private var fileWaiters: [LibraryFileID: [CheckedContinuation<Void, Error>]] = [:]

    private final class Session {
        let id: DeviceID
        let name: String
        let connection: FramedConnection
        var peerKnows: VersionVector
        let kicks: AsyncStream<Void>
        let kick: AsyncStream<Void>.Continuation
        init(id: DeviceID, name: String, connection: FramedConnection, peerKnows: VersionVector) {
            self.id = id; self.name = name; self.connection = connection; self.peerKnows = peerKnows
            (kicks, kick) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        }
    }

    private struct Incoming {
        var handle: FileHandle
        var partURL: URL
        var size: Int64
        var received: Int64
        var hash: String
    }

    public init(library: LibraryStore, device: DeviceStore, key: PairingKey, deviceName: String, mediaDirectory: URL, artwork: ArtworkStore? = nil) {
        self.artwork = artwork
        self.library = library
        self.device = device
        self.access = FileAccessService(device: device)
        self.key = key
        self.deviceName = deviceName
        self.mediaDirectory = mediaDirectory
        (events, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    }

    public var peers: [PeerInfo] {
        sessions.values.map { PeerInfo(id: $0.id, name: $0.name) }
    }

    // MARK: Starting and stopping

    /// Accepts connections from paired devices and announces this device on the local network. Returns the port.
    @discardableResult
    public func startListening() async throws -> UInt16 {
        let id = try await identity()
        let listener = try NWListener(using: FramedConnection.parameters(key: key))
        listener.service = NWListener.Service(name: "\(deviceName)#\(id.uuidString)", type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.run(FramedConnection(connection), outgoing: false) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take(), let port = listener.port?.rawValue { continuation.resume(returning: port) }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: PeeringError.connectionFailed(error.localizedDescription)) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "musicam.peering.listener"))
        }
        self.listener = listener
        return port
    }

    /// Looks for paired devices on the network and connects to them.
    /// To avoid two connections between the same pair, only the device with the smaller ID connects.
    public func startDiscovery() async throws {
        let id = try await identity()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: FramedConnection.parameters(key: key))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { await self.consider(results, myID: id) }
        }
        browser.start(queue: DispatchQueue(label: "musicam.peering.browser"))
        self.browser = browser
    }

    private func consider(_ results: Set<NWBrowser.Result>, myID: DeviceID) async {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  let hash = name.lastIndex(of: "#"),
                  let peerID = UUID(uuidString: String(name[name.index(after: hash)...])),
                  peerID != myID, sessions[peerID] == nil, !connecting.contains(peerID),
                  myID.uuidString < peerID.uuidString else { continue }
            connecting.insert(peerID)
            let connection = NWConnection(to: result.endpoint, using: FramedConnection.parameters(key: key))
            Task {
                await self.run(FramedConnection(connection), outgoing: true)
                self.finishedConnecting(peerID)
            }
        }
    }

    private func finishedConnecting(_ id: DeviceID) {
        connecting.remove(id)
    }

    /// Connects directly to a known address (used when discovery is not available, and by tests).
    public func connect(host: String, port: UInt16) async throws {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                      using: FramedConnection.parameters(key: key))
        let framed = FramedConnection(connection)
        try await framed.start()
        Task { await self.run(framed, outgoing: true, alreadyStarted: true) }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for session in sessions.values { session.connection.cancel() }
    }

    /// Call after the library changes locally (import, edit, delete) so connected devices hear about it now.
    public func localLibraryChanged() {
        for session in sessions.values { session.kick.yield() }
    }

    // MARK: Fetching audio

    /// Makes sure this device holds the audio file, asking a connected device for it if not.
    public func fetchFile(_ fileID: LibraryFileID) async throws {
        if let entry = try await device.entry(for: fileID), entry.state == .present,
           FileManager.default.fileExists(atPath: entry.path) { return }
        guard let session = sessions.values.first else { throw PeeringError.noPeer }
        let alreadyRequested = !(fileWaiters[fileID] ?? []).isEmpty
        let part = partURL(for: fileID)
        let have = ((try? FileManager.default.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let request = Frame(type: .fileRequest, payload: encode(FileRequest(fileID: fileID, offset: have)))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fileWaiters[fileID, default: []].append(continuation)
            guard !alreadyRequested else { return }
            Task {
                do { try await session.connection.send(request) }
                catch { self.failFile(fileID, error: error) }
            }
        }
    }

    // MARK: Session

    private func identity() async throws -> DeviceID {
        if let myID { return myID }
        let id = try await library.deviceIdentity()
        myID = id
        return id
    }

    private func run(_ connection: FramedConnection, outgoing: Bool, alreadyStarted: Bool = false) async {
        var session: Session?
        do {
            if !alreadyStarted { try await connection.start() }
            let me = try await identity()
            let hello = Hello(deviceID: me, deviceName: deviceName, protocolVersion: Self.protocolVersion, vector: try await library.versionVector())
            try await connection.send(Frame(type: .hello, payload: encode(hello)))
            let reply = try await connection.receive()
            guard reply.type == .hello, let peer = try? decoder.decode(Hello.self, from: reply.payload) else {
                throw PeeringError.protocolViolation("expected hello")
            }
            guard peer.protocolVersion == Self.protocolVersion else { throw PeeringError.protocolViolation("different version") }
            guard peer.deviceID != me, sessions[peer.deviceID] == nil else { connection.cancel(); return }

            let made = Session(id: peer.deviceID, name: peer.deviceName, connection: connection, peerKnows: peer.vector)
            session = made
            sessions[peer.deviceID] = made
            continuation.yield(.peerConnected(name: peer.deviceName))

            let sender = Task { await self.sendLoop(made) }
            defer { sender.cancel() }
            while true {
                let frame = try await connection.receive()
                try await handle(frame, from: made)
            }
        } catch {
            if let session {
                sessions[session.id] = nil
                session.kick.finish()
                continuation.yield(.peerDisconnected(name: session.name))
                if sessions.isEmpty { for id in fileWaiters.keys { failFile(id, error: PeeringError.noPeer) } }
            } else if !(error is CancellationError) {
                continuation.yield(.problem("Could not connect: \(error)"))
            }
            connection.cancel()
        }
    }

    private func sendLoop(_ session: Session) async {
        await push(session)
        for await _ in session.kicks { await push(session) }
    }

    /// Sends everything the peer does not have yet, in batches.
    private func push(_ session: Session) async {
        do {
            let missing = try await library.changes(missingFrom: session.peerKnows)
            var index = 0
            while index < missing.count {
                let batch = Array(missing[index..<min(index + Self.batchSize, missing.count)])
                try await session.connection.send(Frame(type: .changes, payload: encode(ChangesBatch(entries: batch))))
                for entry in batch { note(entry.stamp, in: session) }
                index += Self.batchSize
            }
            try await session.connection.send(Frame(type: .syncDone))
        } catch {
            session.connection.cancel()
        }
    }

    private func note(_ stamp: HLCTimestamp, in session: Session) {
        if session.peerKnows.newest[stamp.device].map({ $0 < stamp }) ?? true { session.peerKnows.newest[stamp.device] = stamp }
    }

    private func handle(_ frame: Frame, from session: Session) async throws {
        switch frame.type {
        case .hello:
            throw PeeringError.protocolViolation("unexpected hello")
        case .changes:
            let batch = try decoder.decode(ChangesBatch.self, from: frame.payload)
            let added = try await library.ingest(batch.entries)
            for entry in batch.entries { note(entry.stamp, in: session) }
            if added > 0 { continuation.yield(.recordsReceived(count: added)) }
        case .syncDone:
            continuation.yield(.upToDate)
            await requestMissingArtwork(from: session)
        case .artworkRequest:
            let request = try decoder.decode(ArtworkRequest.self, from: frame.payload)
            Task { await self.serveArtwork(request, to: session) }
        case .artworkData:
            guard let artwork, frame.payload.count > 32,
                  let key = String(data: frame.payload.prefix(32), encoding: .utf8) else { break }
            if artwork.saveReceived(key: key, jpeg: frame.payload.dropFirst(32)) { continuation.yield(.artworkReceived) }
        case .fileRequest:
            let request = try decoder.decode(FileRequest.self, from: frame.payload)
            Task { await self.serve(request, to: session) }
        case .fileHeader:
            try beginReceiving(try decoder.decode(FileHeader.self, from: frame.payload))
        case .fileData:
            try receiveData(frame.payload)
        case .fileEnd:
            try await finishReceiving(try decoder.decode(FileEnd.self, from: frame.payload).fileID)
        case .fileError:
            let failure = try decoder.decode(FileFailure.self, from: frame.payload)
            discardIncoming(failure.fileID)
            failFile(failure.fileID, error: PeeringError.fileFailed(failure.reason))
        }
    }

    // MARK: Covers

    /// Asks the other device for the covers of songs we know about but do not have a picture for.
    private func requestMissingArtwork(from session: Session) async {
        guard let artwork, let tracks = try? await library.allTracks() else { return }
        let wanted = Set(tracks.compactMap(\.artworkKey)).filter { !artwork.has($0) && !askedArtwork.contains($0) }
        guard !wanted.isEmpty else { return }
        askedArtwork.formUnion(wanted)
        let keys = Array(wanted)
        for start in stride(from: 0, to: keys.count, by: 200) {
            let chunk = Array(keys[start..<min(start + 200, keys.count)])
            try? await session.connection.send(Frame(type: .artworkRequest, payload: encode(ArtworkRequest(keys: chunk))))
        }
    }

    private func serveArtwork(_ request: ArtworkRequest, to session: Session) async {
        guard let artwork else { return }
        for key in request.keys.prefix(200) {
            guard key.count == 32, let data = artwork.data(for: key) else { continue }
            try? await session.connection.send(Frame(type: .artworkData, payload: Data(key.utf8) + data))
        }
    }

    // MARK: Sending a file

    private func serve(_ request: FileRequest, to session: Session) async {
        do {
            guard let info = try await library.fileInfo(request.fileID) else { throw PeeringError.fileFailed("unknown file") }
            let file = try await access.open(request.fileID)
            defer { file.release() }
            let size = ((try FileManager.default.attributesOfItem(atPath: file.url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let offset = min(max(0, request.offset), size)
            try await session.connection.send(Frame(type: .fileHeader, payload: encode(
                FileHeader(fileID: request.fileID, size: size, offset: offset, hash: info.contentHash))))
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let idBytes = withUnsafeBytes(of: request.fileID.uuid) { Data($0) }
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                try await session.connection.send(Frame(type: .fileData, payload: idBytes + chunk))
            }
            try await session.connection.send(Frame(type: .fileEnd, payload: encode(FileEnd(fileID: request.fileID))))
        } catch {
            let failure = FileFailure(fileID: request.fileID, reason: String(describing: error))
            try? await session.connection.send(Frame(type: .fileError, payload: encode(failure)))
        }
    }

    // MARK: Receiving a file

    private func partURL(for id: LibraryFileID) -> URL {
        mediaDirectory.appendingPathComponent(id.uuidString + ".part")
    }

    private func beginReceiving(_ header: FileHeader) throws {
        let part = partURL(for: header.fileID)
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        try handle.truncate(atOffset: UInt64(header.offset))     // keep exactly what the sender says we already have
        try handle.seek(toOffset: UInt64(header.offset))
        incoming[header.fileID] = Incoming(handle: handle, partURL: part, size: header.size, received: header.offset, hash: header.hash)
    }

    private func receiveData(_ payload: Data) throws {
        guard payload.count > 16 else { throw PeeringError.protocolViolation("short data frame") }
        let idBytes = payload.prefix(16)
        let id = idBytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        guard var state = incoming[id] else { throw PeeringError.protocolViolation("data without header") }
        let body = payload.dropFirst(16)
        try state.handle.write(contentsOf: body)
        state.received += Int64(body.count)
        incoming[id] = state
        continuation.yield(.fileProgress(id, received: state.received, total: state.size))
    }

    private func finishReceiving(_ id: LibraryFileID) async throws {
        guard let state = incoming.removeValue(forKey: id) else { return }
        try? state.handle.close()
        let digest = try ContentHasher.sha256(of: state.partURL)
        guard digest == state.hash else {
            try? FileManager.default.removeItem(at: state.partURL)      // never keep a corrupt copy; the next try starts clean
            failFile(id, error: PeeringError.fileFailed("checksum mismatch"))
            continuation.yield(.problem("A received file failed its check and was discarded."))
            return
        }
        let name = (try? await library.fileInfo(id))?.originalFilename ?? "\(id.uuidString).audio"
        let final = mediaDirectory.appendingPathComponent(id.uuidString + "." + (URL(fileURLWithPath: name).pathExtension.isEmpty ? "audio" : URL(fileURLWithPath: name).pathExtension))
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: state.partURL, to: final)
        let bookmark = (try? final.bookmarkData(options: FileBookmarks.creation)) ?? Data()
        try await device.register([LocalFileInfo(audioFileID: id, bookmark: bookmark, path: final.path, byteSize: state.size,
                                                 modificationDate: (try? final.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil)])
        continuation.yield(.fileReceived(id))
        for waiter in fileWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    private func discardIncoming(_ id: LibraryFileID) {
        if let state = incoming.removeValue(forKey: id) { try? state.handle.close() }
    }

    private func failFile(_ id: LibraryFileID, error: Error) {
        for waiter in fileWaiters.removeValue(forKey: id) ?? [] { waiter.resume(throwing: error) }
    }

    // MARK: Coding

    private let decoder = JSONDecoder()

    private nonisolated func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}
