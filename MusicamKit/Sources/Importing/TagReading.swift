import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox
import Domain

public struct RawTags: Sendable {
    public var metadata: ExtractedMetadata
    public var artworkData: Data?
}

public enum TagReadError: Error, Sendable, Equatable {
    case notPlayable
    case noAudioTrack
}

public protocol TagReading: Sendable {
    func read(_ url: URL) async throws -> RawTags
}

/// Reads tags and format with AVFoundation (ID3, iTunes/MP4 atoms, Vorbis comments where supported).
public struct AVFoundationTagReader: TagReading {
    public init() {}

    public func read(_ url: URL) async throws -> RawTags {
        let asset = AVURLAsset(url: url)
        let (duration, playable, items) = try await asset.load(.duration, .isPlayable, .metadata)
        guard playable else { throw TagReadError.notPlayable }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TagReadError.noAudioTrack }
        let (descriptions, dataRate) = try await track.load(.formatDescriptions, .estimatedDataRate)

        let title = await string(items, [.commonIdentifierTitle])
        let artist = await string(items, [.commonIdentifierArtist])
        let album = await string(items, [.commonIdentifierAlbumName])
        let albumArtist = await string(items, [.iTunesMetadataAlbumArtist, .id3MetadataBand])
        let genreRaw = await string(items, [.iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre])
        let dateRaw = await string(items, [.commonIdentifierCreationDate, .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate])
        let trackRaw = await numberPair(items, [.id3MetadataTrackNumber, .iTunesMetadataTrackNumber])
        let discRaw = await numberPair(items, [.id3MetadataPartOfASet, .iTunesMetadataDiscNumber])
        let artwork = await data(items, [.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt])

        let stem = url.deletingPathExtension().lastPathComponent
        let seconds = duration.seconds.isFinite ? duration.seconds : 0
        // Some files (for example MP3 without a Xing header) report no data rate; fall back to size / duration.
        var rate = dataRate
        if rate <= 0, seconds > 0, let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            rate = Float(Double(bytes) * 8 / seconds)
        }
        let format = Self.format(from: descriptions.first, dataRate: rate, extension: url.pathExtension)
        let meta = ExtractedMetadata(
            title: (title?.isEmpty == false ? title! : stem),
            artist: artist ?? "", album: album ?? "", albumArtist: albumArtist ?? "",
            trackNumber: trackRaw, discNumber: discRaw, year: Self.year(from: dateRaw),
            genre: Self.cleanGenre(genreRaw), duration: seconds, format: format)
        return RawTags(metadata: meta, artworkData: artwork)
    }

    // MARK: Metadata helpers

    private func firstItem(_ items: [AVMetadataItem], _ ids: [AVMetadataIdentifier]) -> AVMetadataItem? {
        for id in ids {
            if let found = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first { return found }
        }
        return nil
    }

    private func string(_ items: [AVMetadataItem], _ ids: [AVMetadataIdentifier]) async -> String? {
        for id in ids {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                if let s = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
        }
        return nil
    }

    private func data(_ items: [AVMetadataItem], _ ids: [AVMetadataIdentifier]) async -> Data? {
        for id in ids {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                if let d = try? await item.load(.dataValue), !d.isEmpty { return d }
            }
        }
        return nil
    }

    /// "3/12", "3", or the 8-byte iTunes track atom: returns the first number.
    private func numberPair(_ items: [AVMetadataItem], _ ids: [AVMetadataIdentifier]) async -> Int? {
        guard let item = firstItem(items, ids) else { return nil }
        if let s = try? await item.load(.stringValue) {
            let digits = s.split(separator: "/").first.map(String.init) ?? s
            if let n = Int(digits.trimmingCharacters(in: .whitespaces)) { return n }
        }
        if let n = try? await item.load(.numberValue) { return n.intValue }
        if let d = try? await item.load(.dataValue), d.count >= 4 {
            return Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
        }
        return nil
    }

    static func year(from raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.prefix(4)
        guard digits.count == 4, let y = Int(digits), (1000...3000).contains(y) else { return nil }
        return y
    }

    /// ID3 genres can arrive as "(17)Rock" or "(17)"; keep the readable part.
    static func cleanGenre(_ raw: String?) -> String {
        guard var g = raw else { return "" }
        if g.hasPrefix("("), let close = g.firstIndex(of: ")") {
            let rest = g[g.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return "" }
            g = rest
        }
        return g.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Format

    static func format(from description: CMFormatDescription?, dataRate: Float, extension ext: String) -> AudioFormat {
        guard let description,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return AudioFormat(codec: ext.uppercased())
        }
        let bitrate = dataRate > 0 ? Int(dataRate) : nil
        switch asbd.mFormatID {
        case kAudioFormatMPEGLayer3:
            return AudioFormat(codec: "MP3", sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), bitrate: bitrate)
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            return AudioFormat(codec: "AAC", sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), bitrate: bitrate)
        case kAudioFormatAppleLossless:
            let depth: Int?
            switch asbd.mFormatFlags {
            case 1: depth = 16
            case 2: depth = 20
            case 3: depth = 24
            case 4: depth = 32
            default: depth = nil
            }
            return AudioFormat(codec: "ALAC", sampleRate: asbd.mSampleRate, bitDepth: depth, channels: Int(asbd.mChannelsPerFrame), isLossless: true)
        case kAudioFormatFLAC:
            return AudioFormat(codec: "FLAC", sampleRate: asbd.mSampleRate, bitDepth: asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil,
                               channels: Int(asbd.mChannelsPerFrame), isLossless: true)
        case kAudioFormatLinearPCM:
            let codec = ["aif": "AIFF", "aiff": "AIFF", "aifc": "AIFF", "caf": "CAF"][ext.lowercased()] ?? "WAV"
            return AudioFormat(codec: codec, sampleRate: asbd.mSampleRate, bitDepth: Int(asbd.mBitsPerChannel),
                               channels: Int(asbd.mChannelsPerFrame), isLossless: true)
        case kAudioFormatOpus:
            return AudioFormat(codec: "Opus", sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), bitrate: bitrate)
        default:
            return AudioFormat(codec: ext.uppercased(), sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), bitrate: bitrate)
        }
    }
}
