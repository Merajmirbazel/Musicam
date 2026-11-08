import Foundation
import Testing
import SwiftUI
import AppKit
import Domain
import Persistence
import Importing
import Playback
import Peering
@testable import Features

@MainActor
final class NullEngine: PlaybackEngine {
    let events: AsyncStream<EngineEvent>
    var isPlaying = false
    var volume: Float = 1
    init() { (events, _) = AsyncStream<EngineEvent>.makeStream() }
    func load(current: AccessedFile, next: AccessedFile?, autoplay: Bool) {}
    func setNext(_ file: AccessedFile?) {}
    func play() {}
    func pause() {}
    func seek(to seconds: TimeInterval) {}
    func stop() {}
}

struct TestApp {
    let model: AppModel
    let library: LibraryStore
    let device: DeviceStore
    let artwork: ArtworkStore
    let dir: URL

    @MainActor
    static func make() throws -> TestApp {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = try LibraryStore.open(at: nil)
        let device = try DeviceStore.open(at: nil)
        let artwork = ArtworkStore(directory: dir.appendingPathComponent("art"))
        let model = AppModel(libraryStore: library, deviceStore: device, artworkStore: artwork, engine: NullEngine(), nowPlaying: nil,
                             pairing: MemoryPairingStore(), deviceName: "Test", mediaDirectory: dir.appendingPathComponent("media"))
        return TestApp(model: model, library: library, device: device, artwork: artwork, dir: dir)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// Adds a song straight to the store (no audio file) and reloads the model.
    @MainActor
    @discardableResult
    func addSong(_ title: String, artist: String = "Artist", album: String = "Album", hash: String? = nil, artworkKey: String? = nil, source: String = "") async throws -> Track {
        let item = ImportedItem(
            metadata: ExtractedMetadata(title: title, artist: artist, album: album, duration: 200,
                                        format: AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2, isLossless: true),
                                        artworkKey: artworkKey),
            contentHash: hash ?? UUID().uuidString, byteSize: 1_000_000, originalFilename: title + ".flac", source: source)
        let id = try await library.add([item])[0].trackID
        await model.library.load()
        return try #require(model.library.track(id: id))
    }
}

func makeWAV(at url: URL, seed: Int) throws {
    let rate = 8000, frames = 1600
    var pcm = Data()
    for n in 0..<frames {
        var s = Int16(sin(2 * .pi * (200 + Double(seed % 500)) * Double(n) / Double(rate)) * 0.2 * 32767)
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

/// Renders a SwiftUI view offscreen and returns it as a bitmap (no screen-recording permission needed).
@MainActor
func render<V: View>(_ view: V, size: CGSize, settle: Double = 0.6) async -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .seconds(settle))   // lets async artwork loads finish
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

/// Share of pixels that differ clearly from the corner (background) pixel: a quick "is anything drawn" check.
func inkFraction(_ rep: NSBitmapImageRep) -> Double {
    guard let bg = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else { return 0 }
    var inked = 0, total = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            total += 1
            if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.15 { inked += 1 }
        }
    }
    return total == 0 ? 0 : Double(inked) / Double(total)
}

func writePNG(_ rep: NSBitmapImageRep, named name: String) {
    let url = URL(fileURLWithPath: "/tmp/musicam-snap-\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

enum ImportServiceFactory {
    static func make(_ app: TestApp) -> ImportService { ImportService(library: app.library, device: app.device, artwork: app.artwork) }
}
