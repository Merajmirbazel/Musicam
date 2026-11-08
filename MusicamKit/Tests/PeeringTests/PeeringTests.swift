import Testing
import Foundation
import Domain
import Sync
import Persistence
import Importing
@testable import Peering

/// One simulated device: its own library, its own file store, its own sync engine.
private struct Peer {
    let name: String
    let library: LibraryStore
    let device: DeviceStore
    let engine: SyncEngine
    let art: ArtworkStore
    let dir: URL

    init(_ name: String, key: PairingKey) throws {
        self.name = name
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-peer-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        library = try LibraryStore.open(at: nil)
        device = try DeviceStore.open(at: nil)
        art = ArtworkStore(directory: dir.appendingPathComponent("art"))
        engine = SyncEngine(library: library, device: device, key: key, deviceName: name, mediaDirectory: dir.appendingPathComponent("media"), artwork: art)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// Imports real files, the way the Mac app does.
    func importFiles(_ urls: [URL]) async -> ImportSummary {
        let importer = ImportService(library: library, device: device, artwork: art)
        var summary = ImportSummary()
        for await event in importer.run(urls) { if case .finished(let s) = event { summary = s } }
        return summary
    }
}

private func makeWAV(at url: URL, seconds: Double, seed: Int) throws {
    let rate = 8000, frames = Int(Double(rate) * seconds)
    var pcm = Data()
    for n in 0..<frames {
        var s = Int16(sin(2 * .pi * (200 + Double(seed)) * Double(n) / Double(rate)) * 0.2 * 32767)
        if n == 0 { s = Int16(truncatingIfNeeded: seed) }
        withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
    }
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    var wav = Data("RIFF".utf8)
    wav += le32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
    wav += le32(UInt32(rate)) + le32(UInt32(rate * 2)) + le16(2) + le16(16)
    wav += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
    try wav.write(to: url)
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64?
    func set(_ v: Int64) { lock.lock(); stored = v; lock.unlock() }
    var value: Int64? { lock.lock(); defer { lock.unlock() }; return stored }
}

private func eventually(_ seconds: Double = 8, _ condition: () async throws -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return (try? await condition()) == true
}

@Suite(.serialized) struct PeeringTests {
    @Test func pairingKeyRoundTripsThroughItsCode() {
        let key = PairingKey.generate()
        #expect(key.code.split(separator: "-").count == 8)
        #expect(PairingKey(code: key.code) == key)
        #expect(PairingKey(code: key.code.uppercased().replacingOccurrences(of: "-", with: " ")) == key)
        #expect(PairingKey(code: "too short") == nil)
        #expect(PairingKey.generate() != key)
    }

    @Test func coversTravelToTheOtherDeviceAndFakeOnesAreRejected() async throws {
        let key = PairingKey.generate()
        let mac = try Peer("mac", key: key), phone = try Peer("phone", key: key)
        defer { mac.cleanup(); phone.cleanup() }
        let wav = mac.dir.appendingPathComponent("Covered.wav")
        try makeWAV(at: wav, seconds: 0.3, seed: 3)
        _ = await mac.importFiles([wav])
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let coverKey = try #require(mac.art.save(png))
        let id = try await mac.library.allTracks()[0].id
        try await mac.library.edit(trackID: id, TrackEdit(artworkKey: coverKey))

        let port = try await mac.engine.startListening()
        try await phone.engine.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { phone.art.has(coverKey) })
        #expect(phone.art.data(for: coverKey) == mac.art.data(for: coverKey))
        #expect(phone.art.saveReceived(key: String(repeating: "a", count: 32), jpeg: Data("not an image".utf8)) == false)
        #expect(phone.art.saveReceived(key: String(repeating: "b", count: 32), jpeg: mac.art.data(for: coverKey)!) == false)
        await mac.engine.stop(); await phone.engine.stop()
    }

    @Test func aFreshDeviceReceivesTheWholeLibraryOverTheNetwork() async throws {
        let key = PairingKey.generate()
        let mac = try Peer("mac", key: key), phone = try Peer("phone", key: key)
        defer { mac.cleanup(); phone.cleanup() }
        let folder = mac.dir.appendingPathComponent("songs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 1...12 { try makeWAV(at: folder.appendingPathComponent("Song \(i).wav"), seconds: 0.3, seed: i) }
        #expect(await mac.importFiles([folder]).imported == 12)

        let port = try await mac.engine.startListening()
        try await phone.engine.connect(host: "127.0.0.1", port: port)

        #expect(await eventually { try await phone.library.trackCount() == 12 })
        let a = try await mac.library.allTracks().sorted { $0.id.uuidString < $1.id.uuidString }
        let b = try await phone.library.allTracks().sorted { $0.id.uuidString < $1.id.uuidString }
        #expect(a == b)
        await mac.engine.stop(); await phone.engine.stop()
    }

    @Test func laterEditsAndNewSongsReachTheOtherDeviceImmediatelyInBothDirections() async throws {
        let key = PairingKey.generate()
        let mac = try Peer("mac", key: key), phone = try Peer("phone", key: key)
        defer { mac.cleanup(); phone.cleanup() }
        let wav = mac.dir.appendingPathComponent("First.wav")
        try makeWAV(at: wav, seconds: 0.3, seed: 1)
        _ = await mac.importFiles([wav])
        let port = try await mac.engine.startListening()
        try await phone.engine.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { try await phone.library.trackCount() == 1 })

        // edit on the Mac
        let id = try await mac.library.allTracks()[0].id
        try await mac.library.edit(trackID: id, TrackEdit(title: "Renamed on the Mac", isFavorite: true))
        await mac.engine.localLibraryChanged()
        #expect(await eventually { try await phone.library.track(id: id)?.title == "Renamed on the Mac" })

        // a favourite and a rating set on the phone travel back
        try await phone.library.edit(trackID: id, TrackEdit(rating: 5))
        await phone.engine.localLibraryChanged()
        #expect(await eventually { try await mac.library.track(id: id)?.rating == 5 })

        // a song imported on the phone appears on the Mac
        let second = phone.dir.appendingPathComponent("Second.wav")
        try makeWAV(at: second, seconds: 0.3, seed: 2)
        _ = await phone.importFiles([second])
        await phone.engine.localLibraryChanged()
        #expect(await eventually { try await mac.library.trackCount() == 2 })
        await mac.engine.stop(); await phone.engine.stop()
    }

    @Test func anAudioFileIsFetchedOnDemandAndVerified() async throws {
        let key = PairingKey.generate()
        let mac = try Peer("mac", key: key), phone = try Peer("phone", key: key)
        defer { mac.cleanup(); phone.cleanup() }
        let source = mac.dir.appendingPathComponent("Big.wav")
        try makeWAV(at: source, seconds: 12, seed: 7)               // about 190 KB: several chunks
        _ = await mac.importFiles([source])
        let port = try await mac.engine.startListening()
        try await phone.engine.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { try await phone.library.trackCount() == 1 })

        let fileID = try #require(try await phone.library.allTracks().first?.file?.id)
        #expect(try await phone.device.entry(for: fileID) == nil)   // the phone knows the song but holds no audio yet
        try await phone.engine.fetchFile(fileID)

        let access = try await FileAccessService(device: phone.device).open(fileID)
        #expect(try Data(contentsOf: access.url) == Data(contentsOf: source))
        #expect(access.url.resolvingSymlinksInPath().path.hasPrefix(phone.dir.resolvingSymlinksInPath().path))          // stored inside the phone's own area
        access.release()
        await mac.engine.stop(); await phone.engine.stop()
    }

    @Test func aTransferInterruptedEarlierResumesFromWhatWasAlreadyReceived() async throws {
        let key = PairingKey.generate()
        let mac = try Peer("mac", key: key), phone = try Peer("phone", key: key)
        defer { mac.cleanup(); phone.cleanup() }
        let source = mac.dir.appendingPathComponent("Resume.wav")
        try makeWAV(at: source, seconds: 12, seed: 9)
        _ = await mac.importFiles([source])
        let port = try await mac.engine.startListening()
        try await phone.engine.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { try await phone.library.trackCount() == 1 })
        let fileID = try #require(try await phone.library.allTracks().first?.file?.id)

        // pretend an earlier attempt got 40% of the way
        let whole = try Data(contentsOf: source)
        let media = phone.dir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try whole.prefix(whole.count * 4 / 10).write(to: media.appendingPathComponent(fileID.uuidString + ".part"))

        let firstProgress = ProgressBox()
        let watcher = Task {
            for await event in phone.engine.events {
                if case .fileProgress(_, let received, _) = event { firstProgress.set(received); break }
            }
        }
        try await phone.engine.fetchFile(fileID)
        _ = await watcher.result
        let access = try await FileAccessService(device: phone.device).open(fileID)
        #expect(try Data(contentsOf: access.url) == whole)
        #expect((firstProgress.value ?? 0) > Int64(whole.count) * 4 / 10)  // the first progress report is past the saved 40%
        access.release()
        await mac.engine.stop(); await phone.engine.stop()
    }

    @Test func aDeviceWithADifferentKeyIsRejectedAndLearnsNothing() async throws {
        let mac = try Peer("mac", key: PairingKey.generate())
        let stranger = try Peer("stranger", key: PairingKey.generate())
        defer { mac.cleanup(); stranger.cleanup() }
        let wav = mac.dir.appendingPathComponent("Private.wav")
        try makeWAV(at: wav, seconds: 0.3, seed: 3)
        _ = await mac.importFiles([wav])
        let port = try await mac.engine.startListening()

        await #expect(throws: (any Error).self) {
            try await stranger.engine.connect(host: "127.0.0.1", port: port)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await stranger.library.trackCount() == 0)
        #expect(await mac.engine.peers.isEmpty)
        await mac.engine.stop()
    }

    @Test func fetchingWithoutAnyConnectedDeviceFailsClearly() async throws {
        let peer = try Peer("alone", key: PairingKey.generate())
        defer { peer.cleanup() }
        await #expect(throws: PeeringError.noPeer) {
            try await peer.engine.fetchFile(UUID())
        }
    }
}

@Suite struct PairingLinkTests {
    @Test func linkAndBareCodeBothParseAndOtherLinksDoNot() {
        let key = PairingKey.generate()
        #expect(key.pairingLink.hasPrefix("musicam://pair?code="))
        #expect(PairingKey(scanned: key.pairingLink) == key)
        #expect(PairingKey(scanned: "  " + key.code.uppercased() + "\n") == key)
        #expect(PairingKey(scanned: "https://example.com/?code=" + key.code) == nil)     // a foreign link is never guessed at
        #expect(PairingKey(scanned: "musicam://pair?code=abc") == nil)
        #expect(PairingKey(scanned: "musicam://pair") == nil)
        #expect(PairingKey(scanned: "hello") == nil)
    }
}
