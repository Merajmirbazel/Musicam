import Foundation

public enum DirectDownloadError: Error, Equatable, LocalizedError {
    case notHTTPS, notAudio, tooLarge, failed(Int)

    public var errorDescription: String? {
        switch self {
        case .notHTTPS: String(localized: "Only https links can be downloaded.")
        case .notAudio: String(localized: "That link is not a direct audio file.")
        case .tooLarge: String(localized: "That file is too large.")
        case .failed(let code): String(localized: "The server answered with error \(code).")
        }
    }
}

/// Downloads one audio file from a link that points straight at it. It refuses anything that is not an audio file,
/// so a web page or a streaming service link can never be "downloaded" this way.
public struct DirectAudioDownloader: Sendable {
    public static let maxBytes: Int64 = 1_500_000_000
    private let session: URLSession
    private let directory: URL

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    /// Returns the saved file's location (inside `directory`, in a folder of its own).
    public func download(_ url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https" else { throw DirectDownloadError.notHTTPS }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (temp, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse else { throw DirectDownloadError.failed(0) }
        guard (200..<300).contains(http.statusCode) else { throw DirectDownloadError.failed(http.statusCode) }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let extensionOK = AudioFileScanner.isAudio(url)
        guard type.hasPrefix("audio/") || (extensionOK && (type.hasPrefix("application/octet-stream") || type.isEmpty)) else {
            throw DirectDownloadError.notAudio
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: temp.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size <= Self.maxBytes else { throw DirectDownloadError.tooLarge }

        let name = Self.fileName(for: url)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    static func fileName(for url: URL) -> String {
        let raw = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let safe = raw.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "download.audio" : safe
    }
}
