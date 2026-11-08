import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Domain
import Persistence
@testable import Importing

enum FixtureError: Error { case exportUnavailable, imageFailed }

/// Fresh scratch folder, removed by the caller.
func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A small valid WAV (16-bit mono). `seed` makes the bytes unique so files are not duplicates of each other.
func makeWAV(at url: URL, seconds: Double = 0.2, sampleRate: Int = 8000, seed: Int = 0) throws {
    let frames = max(1, Int(Double(sampleRate) * seconds))
    var pcm = Data(capacity: frames * 2)
    let freq = 200.0 + Double(seed % 700)
    for n in 0..<frames {
        var sample = Int16(sin(2 * .pi * freq * Double(n) / Double(sampleRate)) * 0.3 * 32767)
        if n == 0 { sample = Int16(truncatingIfNeeded: seed) }
        withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
    }
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    var wav = Data("RIFF".utf8)
    wav += le32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
    wav += le32(UInt32(sampleRate)) + le32(UInt32(sampleRate * 2)) + le16(2) + le16(16)
    wav += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
    try wav.write(to: url)
}

/// An MP3 made of silent frames with an ID3v2.3 tag (UTF-16 text, so Persian works).
func makeMP3(at url: URL, title: String, artist: String, album: String, track: String, year: String, genre: String, frames: Int = 40) throws {
    func textFrame(_ id: String, _ text: String) -> Data {
        var body = Data([0x01, 0xFF, 0xFE])
        body += text.data(using: .utf16LittleEndian)!
        var frame = Data(id.utf8)
        frame += withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame += Data([0, 0])
        return frame + body
    }
    let content = textFrame("TIT2", title) + textFrame("TPE1", artist) + textFrame("TALB", album)
        + textFrame("TRCK", track) + textFrame("TYER", year) + textFrame("TCON", genre)
    let size = content.count
    let synchsafe = Data([UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
    var file = Data("ID3".utf8) + Data([0x03, 0x00, 0x00]) + synchsafe + content
    // MPEG-1 Layer III, 128 kbps, 44.1 kHz, stereo: 417 bytes per frame
    let silentFrame = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(count: 413)
    for _ in 0..<frames { file += silentFrame }
    try file.write(to: url)
}

func makePNG(size: Int = 64) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.imageFailed }
    ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = ctx.makeImage() else { throw FixtureError.imageFailed }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw FixtureError.imageFailed }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw FixtureError.imageFailed }
    return out as Data
}

/// An AAC .m4a with iTunes-style tags and optional cover art, produced by exporting a WAV.
func makeTaggedM4A(at url: URL, from wav: URL, title: String, artist: String, album: String, year: String, genre: String, artwork: Data?) async throws {
    guard let session = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else { throw FixtureError.exportUnavailable }
    var items: [AVMetadataItem] = []
    func add(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) {
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value
        m.extendedLanguageTag = "und"
        items.append(m)
    }
    add(.commonIdentifierTitle, title as NSString)
    add(.commonIdentifierArtist, artist as NSString)
    add(.commonIdentifierAlbumName, album as NSString)
    add(.iTunesMetadataReleaseDate, year as NSString)
    add(.iTunesMetadataUserGenre, genre as NSString)
    if let artwork { add(.commonIdentifierArtwork, artwork as NSData) }
    session.metadata = items
    try await session.export(to: url, as: .m4a)
}

struct Harness {
    let service: ImportService
    let library: LibraryStore
    let device: DeviceStore
    let artwork: ArtworkStore
    let dir: URL

    init() throws {
        dir = try makeTempDir()
        library = try LibraryStore.open(at: nil)
        device = try DeviceStore.open(at: nil)
        artwork = ArtworkStore(directory: dir.appendingPathComponent("artwork"))
        service = ImportService(library: library, device: device, artwork: artwork)
    }

    func importAll(_ urls: [URL], source: String? = nil) async -> ImportSummary {
        var result = ImportSummary()
        for await event in service.run(urls, source: source) {
            if case .finished(let s) = event { result = s }
        }
        return result
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
