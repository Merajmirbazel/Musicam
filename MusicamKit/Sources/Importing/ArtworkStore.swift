import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cover images, stored once each as small JPEGs named by their own hash, so duplicates cost nothing.
public struct ArtworkStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Downscales to at most 800 px and returns the key, or nil if the data is not an image.
    public func save(_ imageData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 800,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let jpeg = output as Data
        let key = String(ContentHasher.sha256(of: jpeg).prefix(32))
        let file = url(for: key)
        if !FileManager.default.fileExists(atPath: file.path) {
            do { try jpeg.write(to: file, options: .atomic) } catch { return nil }
        }
        return key
    }

    public func has(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    /// Stores a cover received from another device as it is, but only if it really is the image its key names.
    @discardableResult
    public func saveReceived(key: String, jpeg: Data) -> Bool {
        guard key.count == 32, key.allSatisfy(\.isHexDigit),
              String(ContentHasher.sha256(of: jpeg).prefix(32)) == key,
              CGImageSourceCreateWithData(jpeg as CFData, nil) != nil else { return false }
        do { try jpeg.write(to: url(for: key), options: .atomic); return true } catch { return false }
    }

    public func url(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    public func data(for key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }
}
