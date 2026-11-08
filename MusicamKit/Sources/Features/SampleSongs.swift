#if DEBUG
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Debug-only: makes real tagged .m4a files (soft tones plus a cover each) so the app can be exercised
/// end to end without anyone's music. Never compiled into release builds.
public enum SampleSongs {
    struct Spec {
        var title: String, artist: String, album: String, year: String, genre: String
        var colors: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        var seconds: Double
        var hz: Double
    }

    static let specs: [Spec] = [
        Spec(title: "Late Night Drive", artist: "Nova Lane", album: "City Static", year: "2022", genre: "Electronic", colors: (0.48, 0.23, 0.93, 0.96, 0.45, 0.71), seconds: 32, hz: 220),
        Spec(title: "Glass Hours", artist: "Nova Lane", album: "City Static", year: "2022", genre: "Electronic", colors: (0.40, 0.30, 0.90, 0.90, 0.40, 0.75), seconds: 28, hz: 247),
        Spec(title: "Saffron Skies", artist: "The Quiet Hours", album: "Saffron Skies", year: "2021", genre: "Ambient", colors: (0.96, 0.62, 0.04, 0.94, 0.27, 0.27), seconds: 30, hz: 262),
        Spec(title: "Slow Tide", artist: "The Quiet Hours", album: "Saffron Skies", year: "2021", genre: "Ambient", colors: (0.92, 0.55, 0.10, 0.85, 0.30, 0.30), seconds: 26, hz: 294),
        Spec(title: "Paper Lanterns", artist: "Kian & Co", album: "Lanterns EP", year: "2019", genre: "Indie", colors: (0.02, 0.71, 0.83, 0.39, 0.40, 0.95), seconds: 34, hz: 330),
        Spec(title: "Rooftop Radio", artist: "Kian & Co", album: "Lanterns EP", year: "2019", genre: "Indie", colors: (0.06, 0.73, 0.51, 0.23, 0.51, 0.96), seconds: 24, hz: 349),
        Spec(title: "نیمه‌شب", artist: "گروه نمونه", album: "شب‌نامه", year: "2018", genre: "Pop", colors: (0.93, 0.28, 0.60, 0.98, 0.45, 0.09), seconds: 29, hz: 392),
        Spec(title: "Cold Coffee", artist: "Marlow", album: "Weekdays", year: "2023", genre: "Jazz", colors: (0.55, 0.36, 0.96, 0.02, 0.71, 0.83), seconds: 31, hz: 440),
        Spec(title: "Harbour Lights", artist: "Marlow", album: "Weekdays", year: "2023", genre: "Jazz", colors: (0.08, 0.72, 0.65, 0.64, 0.90, 0.21), seconds: 27, hz: 466),
        Spec(title: "Static Bloom", artist: "Nova Lane", album: "Bloom", year: "2024", genre: "Electronic", colors: (0.93, 0.28, 0.60, 0.55, 0.36, 0.96), seconds: 33, hz: 523),
    ]

    /// Writes the files into `directory` and returns their URLs.
    public static func generate(into directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, spec) in specs.enumerated() {
            let wav = directory.appendingPathComponent("tone-\(index).wav")
            try writeTone(to: wav, seconds: spec.seconds, hz: spec.hz)
            let m4a = directory.appendingPathComponent(String(format: "%02d.m4a", index + 1))
            try? FileManager.default.removeItem(at: m4a)
            try await export(wav: wav, to: m4a, spec: spec)
            try? FileManager.default.removeItem(at: wav)
            urls.append(m4a)
        }
        return urls
    }

    private static func writeTone(to url: URL, seconds: Double, hz: Double) throws {
        let rate = 22_050
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * 2)
        for n in 0..<frames {
            let t = Double(n) / Double(rate)
            let fade = min(1, min(t, seconds - t) * 4)
            let s = Int16(sin(2 * .pi * hz * t) * 0.06 * fade * 32767)
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

    private static func export(wav: URL, to url: URL, spec: Spec) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var items: [AVMetadataItem] = []
        func add(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        add(.commonIdentifierTitle, spec.title as NSString)
        add(.commonIdentifierArtist, spec.artist as NSString)
        add(.commonIdentifierAlbumName, spec.album as NSString)
        add(.iTunesMetadataReleaseDate, spec.year as NSString)
        add(.iTunesMetadataUserGenre, spec.genre as NSString)
        if let png = cover(spec.colors) { add(.commonIdentifierArtwork, png as NSData) }
        session.metadata = items
        try await session.export(to: url, as: .m4a)
    }

    private static func cover(_ c: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)) -> Data? {
        let size = 600
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1), CGColor(red: c.3, green: c.4, blue: c.5, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.fillEllipse(in: CGRect(x: 90, y: 90, width: 420, height: 420))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
#endif
