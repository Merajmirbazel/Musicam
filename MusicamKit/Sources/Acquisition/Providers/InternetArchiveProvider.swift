import Foundation
import Domain
import Importing
import Metadata

/// Lists the audio files of one Internet Archive item.
public protocol ArchiveListing: Sendable {
    func files(of identifier: String) async throws -> [ArchiveFile]
}

extension InternetArchiveClient: ArchiveListing {}

/// Gets audio from the Internet Archive (archive.org), a library of public-domain and openly licensed recordings:
/// a link to one file downloads that file; a link to an item page downloads the item's audio files (up to `maxFiles`).
/// The download itself is the same `DirectAudioDownloader` the direct-link provider uses.
public struct InternetArchiveProvider: MediaProvider {
    public let id = "internet-archive"
    public var displayName: String { "Internet Archive" }
    private let directory: URL
    private let listing: any ArchiveListing
    private let session: URLSession
    private let maxFiles: Int

    public init(directory: URL, listing: any ArchiveListing = InternetArchiveClient(), session: URLSession = .shared, maxFiles: Int = 25) {
        self.directory = directory
        self.listing = listing
        self.session = session
        self.maxFiles = max(1, maxFiles)
    }

    enum Target: Equatable {
        case file(URL)
        case item(String)
    }

    static func target(for url: URL) -> Target? {
        guard let host = url.host?.lowercased(), host == "archive.org" || host == "www.archive.org" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "details": return .item(parts[1])
        case "download":
            if parts.count >= 3 { return AudioFileScanner.isAudio(url) ? .file(url) : nil }
            return .item(parts[1])
        default: return nil
        }
    }

    public func canHandle(_ request: AcquisitionRequest) -> Bool {
        guard let url = request.url else { return false }
        return Self.target(for: url) != nil
    }

    public func acquire(_ request: AcquisitionRequest, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile] {
        guard let url = request.url, let target = Self.target(for: url) else {
            throw AcquisitionError.invalidRequest(String(localized: "That is not an Internet Archive link."))
        }
        switch target {
        case .file(let fileURL):
            progress(AcquisitionProgress(message: String(localized: "Downloading…")))
            let file = try await download(fileURL)
            progress(AcquisitionProgress(fraction: 1))
            return [file]
        case .item(let identifier):
            return try await downloadItem(identifier, progress: progress)
        }
    }

    private func downloadItem(_ identifier: String, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile] {
        progress(AcquisitionProgress(message: String(localized: "Looking at the item…")))
        let files: [ArchiveFile]
        do { files = try await listing.files(of: identifier) } catch { throw AcquisitionError.mapped(error, provider: id) }
        let chosen = Array(files.prefix(maxFiles))
        guard !chosen.isEmpty else {
            throw AcquisitionError.failed(provider: id, reason: String(localized: "This item has no audio files to download."), retryable: false)
        }
        var done: [AcquiredFile] = []
        for (index, file) in chosen.enumerated() {
            do {
                try Task.checkCancellation()
                progress(AcquisitionProgress(fraction: Double(index) / Double(chosen.count), message: file.title))
                done.append(try await download(file.url))
            } catch {
                // Cancelled: take back what was downloaded. Failed halfway: keep the songs that did arrive.
                if error is CancellationError || (error as? AcquisitionError) == .cancelled {
                    done.forEach { $0.discard() }
                    throw CancellationError()
                }
                if done.isEmpty { throw error }
                break
            }
        }
        progress(AcquisitionProgress(fraction: 1))
        return done
    }

    private func download(_ url: URL) async throws -> AcquiredFile {
        do {
            let file = try await DirectAudioDownloader(directory: directory, session: session).download(url)
            return AcquiredFile(url: file, source: TrackSource.link(url: url).raw, providerID: id, ownsFolder: true)
        } catch {
            throw AcquisitionError.mapped(error, provider: id)
        }
    }
}
