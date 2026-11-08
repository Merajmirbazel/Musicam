import Foundation

/// Everything that can go wrong while getting a file, in a form the interface can show and act on.
public enum AcquisitionError: Error, Equatable, Sendable, LocalizedError {
    /// No registered provider can serve this request.
    case noProvider
    /// The request itself is unusable (for example it has neither a link nor a search text).
    case invalidRequest(String)
    /// The person cancelled.
    case cancelled
    /// The provider finished but nothing it returned could be imported.
    case noUsableFiles(String)
    /// The provider failed. `retryable` tells whether trying again can help (network trouble) or not (wrong file type).
    case failed(provider: String, reason: String, retryable: Bool)
    /// A provider with this id is already registered.
    case duplicateProvider(String)

    public var errorDescription: String? {
        switch self {
        case .noProvider: String(localized: "Musicam does not know how to get that.")
        case .invalidRequest(let why): why
        case .cancelled: String(localized: "Cancelled.")
        case .noUsableFiles(let why): why
        case .failed(_, let reason, _): reason
        case .duplicateProvider(let id): String(localized: "A provider named “\(id)” is already registered.")
        }
    }

    /// Whether "Try again" makes sense.
    public var isRetryable: Bool {
        switch self {
        case .failed(_, _, let retryable): retryable
        case .cancelled: true
        default: false
        }
    }
}

/// One way of getting audio files. A provider only answers three questions: is this request mine, can you fetch it, and
/// how far are you. What happens to the files afterwards (checking, importing) is the manager's job, the same for all providers.
public protocol MediaProvider: Sendable {
    /// A short stable name ("direct-audio"). Two providers may not share one.
    var id: String { get }
    /// A name for the interface.
    var displayName: String { get }

    /// Whether this provider is the right one for the request. Must be quick and must not use the network.
    func canHandle(_ request: AcquisitionRequest) -> Bool

    /// Fetches the request and returns the files as local URLs. Report progress through `progress`. Stop promptly
    /// when the task is cancelled (throw `CancellationError`), leaving no half-made files behind. Throw
    /// `AcquisitionError` for problems the interface should explain.
    func acquire(_ request: AcquisitionRequest, progress: @escaping @Sendable (AcquisitionProgress) -> Void) async throws -> [AcquiredFile]
}
