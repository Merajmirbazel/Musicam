import Foundation

/// What the person (or another part of the app) wants to get. A request is only a description: it says nothing about
/// where the file comes from. Which provider handles it is decided by the `ProviderRegistry`.
public struct AcquisitionRequest: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// A link to the thing to fetch, when there is one.
    public var url: URL?
    /// Free text to look up, for providers that search instead of following a link.
    public var query: String?
    /// What the requester already knows about the song; providers may use it, none has to.
    public var titleHint: String?
    public var artistHint: String?
    /// Extra settings a particular provider understands. The core never reads these.
    public var options: [String: String]

    public init(id: UUID = UUID(), url: URL? = nil, query: String? = nil, titleHint: String? = nil,
                artistHint: String? = nil, options: [String: String] = [:]) {
        self.id = id
        self.url = url
        self.query = query
        self.titleHint = titleHint
        self.artistHint = artistHint
        self.options = options
    }

    public static func link(_ url: URL) -> AcquisitionRequest { AcquisitionRequest(url: url) }

    /// A request with neither a link nor a search text cannot be served by anyone.
    public var isEmpty: Bool {
        url == nil && (query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// How far a provider is. `fraction` is nil when the provider cannot tell (the interface then shows a spinner).
public struct AcquisitionProgress: Sendable, Equatable {
    public var fraction: Double?
    public var message: String?

    public init(fraction: Double? = nil, message: String? = nil) {
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.message = message
    }

    public static let waiting = AcquisitionProgress()
}
