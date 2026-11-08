import Foundation
import Observation
import Metadata

/// Looks for downloadable songs on the Internet Archive and hands the chosen file to the same link importer the
/// "Add from Link" sheet uses. Nothing is sent until the person asks for an online search.
@MainActor
@Observable
public final class OnlineSearchModel {
    public private(set) var items: [ArchiveItem] = []
    public private(set) var files: [ArchiveFile] = []
    public private(set) var isSearching = false
    public private(set) var isLoadingFiles = false
    public private(set) var searchedFor: String?
    public private(set) var message: String?
    /// Files that were handed to the importer in this session, so a row can show a check mark.
    public private(set) var added: Set<String> = []
    public private(set) var downloading: Set<String> = []

    @ObservationIgnored private let client: InternetArchiveClient
    @ObservationIgnored private let download: @MainActor (URL) async -> WishlistModel.Outcome

    public init(client: InternetArchiveClient = InternetArchiveClient(), download: @escaping @MainActor (URL) async -> WishlistModel.Outcome) {
        self.client = client
        self.download = download
    }

    public func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isSearching else { return }
        isSearching = true
        message = nil
        defer { isSearching = false }
        do {
            items = try await client.search(q)
            searchedFor = q
            if items.isEmpty { message = String(localized: "Nothing found online.") }
        } catch {
            items = []
            message = String(localized: "Could not search online. Check the connection and try again.")
        }
    }

    public func clear() { items = []; files = []; searchedFor = nil; message = nil }

    public func loadFiles(of item: ArchiveItem) async {
        isLoadingFiles = true
        files = []
        message = nil
        defer { isLoadingFiles = false }
        do {
            files = try await client.files(of: item.identifier)
            if files.isEmpty { message = String(localized: "This item has no audio files to download.") }
        } catch {
            message = String(localized: "Could not load this item. Check the connection and try again.")
        }
    }

    public func get(_ file: ArchiveFile) async {
        guard !downloading.contains(file.id) else { return }
        downloading.insert(file.id)
        defer { downloading.remove(file.id) }
        switch await download(file.url) {
        case .imported: added.insert(file.id); message = nil
        case .failed(let text): message = text
        default: message = String(localized: "That file could not be added.")
        }
    }
}
