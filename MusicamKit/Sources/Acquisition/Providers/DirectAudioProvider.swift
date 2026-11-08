import Foundation
import Domain
import Importing
import Metadata

extension AcquisitionError {
    /// Turns what a download threw into something the interface can explain. Cancellation stays cancellation.
    static func mapped(_ error: Error, provider: String) -> Error {
        if error is CancellationError || error is AcquisitionError { return error }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            return AcquisitionError.failed(provider: provider, reason: url.localizedDescription, retryable: true)
        }
        if let direct = error as? DirectDownloadError {
            let retryable: Bool
            if case .failed(let code) = direct { retryable = code >= 500 || code == 429 || code == 408 } else { retryable = false }
            return AcquisitionError.failed(provider: provider, reason: direct.localizedDescription, retryable: retryable)
        }
        return AcquisitionError.failed(provider: provider, reason: error.localizedDescription, retryable: false)
    }
}

/// Downloads one audio file from a link that points straight at it, with `DirectAudioDownloader` (https only, audio only).
/// Files go to `directory/<random folder>/<file name>`, the same layout the app always used.
public struct DirectAudioProvider: MediaProvider {
    public let id = "direct-audio"
    public var displayName: String { String(localized: "Direct audio link") }
    private let directory: URL
    private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    public func canHandle(_ request: AcquisitionRequest) -> Bool {
        guard let url = request.url else { return false }
        if case .directAudio = LinkParser.classify(url.absoluteString) { return true }
        return false
    }

    public func acquire(_ request: AcquisitionRequest, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile] {
        guard let url = request.url else { throw AcquisitionError.invalidRequest(String(localized: "There is no link to download.")) }
        progress(AcquisitionProgress(message: String(localized: "Downloading…")))
        do {
            let file = try await DirectAudioDownloader(directory: directory, session: session).download(url)
            progress(AcquisitionProgress(fraction: 1))
            return [AcquiredFile(url: file, source: TrackSource.link(url: url).raw, providerID: id, ownsFolder: true)]
        } catch {
            throw AcquisitionError.mapped(error, provider: id)
        }
    }
}
