import Foundation

public struct ArchiveItem: Identifiable, Hashable, Sendable {
    public var id: String { identifier }
    public let identifier: String
    public let title: String
    public let creator: String
    public init(identifier: String, title: String, creator: String) { self.identifier = identifier; self.title = title; self.creator = creator }
}

public struct ArchiveFile: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let url: URL
    public init(name: String, size: Int64, url: URL) { self.name = name; self.size = size; self.url = url }
    /// A readable title taken from the file name.
    public var title: String {
        let base = (name as NSString).lastPathComponent
        return (base as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    }
}

public enum ArchiveError: Error, Equatable { case badStatus(Int), badResponse }

/// Searches the Internet Archive (archive.org), a free library of public-domain and openly licensed audio, and lists
/// the audio files of an item. Every file it returns is a direct download link the Archive itself offers.
public struct InternetArchiveClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func search(_ query: String, rows: Int = 15) async throws -> [ArchiveItem] {
        let cleaned = query.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        c.queryItems = [.init(name: "q", value: "(\(cleaned)) AND mediatype:audio"),
                        .init(name: "fl[]", value: "identifier"), .init(name: "fl[]", value: "title"), .init(name: "fl[]", value: "creator"),
                        .init(name: "sort[]", value: "downloads desc"), .init(name: "rows", value: String(rows)),
                        .init(name: "page", value: "1"), .init(name: "output", value: "json")]
        return try Self.parseSearch(try await get(c.url!))
    }

    public func files(of identifier: String) async throws -> [ArchiveFile] {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier)") else { return [] }
        return try Self.parseFiles(try await get(url), identifier: identifier)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArchiveError.badResponse }
        guard http.statusCode == 200 else { throw ArchiveError.badStatus(http.statusCode) }
        return data
    }

    static func parseSearch(_ data: Data) throws -> [ArchiveItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = (root["response"] as? [String: Any])?["docs"] as? [[String: Any]] else { throw ArchiveError.badResponse }
        return docs.compactMap { d in
            guard let id = d["identifier"] as? String else { return nil }
            let title = (d["title"] as? String) ?? id
            let creator: String
            if let list = d["creator"] as? [String] { creator = list.joined(separator: ", ") } else { creator = (d["creator"] as? String) ?? "" }
            return ArchiveItem(identifier: id, title: title, creator: creator)
        }
    }

    /// Original MP3/M4A/FLAC files only (the Archive also lists derived copies and spectrograms).
    static func parseFiles(_ data: Data, identifier: String) throws -> [ArchiveFile] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { throw ArchiveError.badResponse }
        let wanted: Set<String> = ["mp3", "m4a", "flac", "ogg"]
        var seenTitles = Set<String>()
        var out: [ArchiveFile] = []
        for f in files {
            guard let name = f["name"] as? String else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard wanted.contains(ext), ext != "ogg" else { continue }
            let size = (f["size"] as? String).flatMap(Int64.init) ?? (f["size"] as? Int64) ?? 0
            let encoded = name.split(separator: "/", omittingEmptySubsequences: true).map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            guard let url = URL(string: "https://archive.org/download/\(identifier)/\(encoded)") else { continue }
            let file = ArchiveFile(name: name, size: size, url: url)
            // an item often holds the same song as MP3 and as FLAC: offer it once, preferring MP3
            let key = file.title.lowercased()
            if seenTitles.contains(key) { continue }
            seenTitles.insert(key)
            out.append(file)
        }
        return out.sorted { $0.name < $1.name }
    }
}
