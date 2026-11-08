import Foundation
import CoreGraphics
import ImageIO
import Observation
import Importing

/// Loads cover images at the size a view needs, so a list of 2,000 songs never holds 2,000 full-size pictures.
/// Works on macOS and iOS: views draw the result with `Image(decorative:scale:)`.
@MainActor
@Observable
public final class ArtworkImageCache {
    @ObservationIgnored private let store: ArtworkStore
    @ObservationIgnored private let cache = NSCache<NSString, CGImage>()
    /// Goes up whenever new covers arrive from another device, so views that showed a placeholder try again.
    public private(set) var revision = 0

    public func coversArrived() { revision += 1 }

    public init(store: ArtworkStore) {
        self.store = store
        cache.countLimit = 600
    }

    /// `maxPoints` is the largest side the view will draw, in points (assumes a 2x screen).
    public func image(for key: String?, maxPoints: CGFloat) async -> CGImage? {
        guard let key else { return nil }
        let pixels = max(32, Int(maxPoints * 2))
        let cacheKey = "\(key)@\(pixels)" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let decoded = await Self.decode(store.url(for: key), maxPixel: pixels) else { return nil }
        cache.setObject(decoded, forKey: cacheKey)
        return decoded
    }

    @concurrent
    private static func decode(_ url: URL, maxPixel: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
