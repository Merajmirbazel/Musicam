import Foundation
import AVFoundation

/// Replaces what FFmpeg did for AAC audio: the m4a that comes from YouTube is a "DASH" file (fragmented MP4) that
/// AVFoundation reads with twice its real length. Copying the audio samples into a normal m4a (no re-encoding)
/// fixes the length, and the same step writes title, artist, album, year and the cover.
enum M4ATagger {
    struct Tags {
        var title: String
        var artist: String
        var album: String?
        var year: String?
        var cover: Data?
    }

    enum Failure: Error, LocalizedError {
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .exportFailed(let s): String(localized: "Could not finish the audio file: \(s)")
            }
        }
    }

    /// Writes `output` from `raw`. The caller deletes `raw` afterwards.
    static func finish(raw: URL, output: URL, tags: Tags) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: raw)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.exportFailed("no export session")
        }
        session.metadata = items(for: tags)
        do { try await session.export(to: output, as: .m4a) } catch {
            try? FileManager.default.removeItem(at: output)
            throw Failure.exportFailed(error.localizedDescription)
        }
    }

    static func items(for tags: Tags) -> [AVMetadataItem] {
        var out: [AVMetadataItem] = []
        func add(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, type: String? = nil) {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            item.extendedLanguageTag = "und"
            if let type { item.dataType = type }
            out.append(item)
        }
        if !tags.title.isEmpty { add(.commonIdentifierTitle, tags.title as NSString) }
        if !tags.artist.isEmpty { add(.commonIdentifierArtist, tags.artist as NSString) }
        if let album = tags.album, !album.isEmpty { add(.commonIdentifierAlbumName, album as NSString) }
        if let year = tags.year, !year.isEmpty { add(.commonIdentifierCreationDate, year as NSString) }
        if let cover = tags.cover, !cover.isEmpty {
            let isPNG = cover.starts(with: [0x89, 0x50, 0x4E, 0x47])
            add(.commonIdentifierArtwork, cover as NSData, type: isPNG ? "public.png" : "public.jpeg")
        }
        return out
    }
}
