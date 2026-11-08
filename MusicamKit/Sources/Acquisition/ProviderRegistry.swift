import Foundation
import Synchronization

/// The list of providers. The first registered provider that says it can handle a request wins, so more specific
/// providers (for one website) go before general ones (any direct audio link).
public final class ProviderRegistry: Sendable {
    private let storage = Mutex<[any MediaProvider]>([])

    public init() {}

    /// Builds a registry from a list. Throws if two providers share an id.
    public convenience init(_ providers: [any MediaProvider]) throws {
        self.init()
        for provider in providers { try register(provider) }
    }

    public var providers: [any MediaProvider] { storage.withLock { $0 } }

    /// Adds a provider. Throws `duplicateProvider` when its id is taken.
    public func register(_ provider: any MediaProvider) throws {
        try storage.withLock { list in
            guard !list.contains(where: { $0.id == provider.id }) else { throw AcquisitionError.duplicateProvider(provider.id) }
            list.append(provider)
        }
    }

    @discardableResult
    public func unregister(id: String) -> Bool {
        storage.withLock { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            list.remove(at: index)
            return true
        }
    }

    public func provider(withID id: String) -> (any MediaProvider)? { providers.first { $0.id == id } }

    /// The provider for a request, or nil.
    public func resolve(_ request: AcquisitionRequest) -> (any MediaProvider)? {
        providers.first { $0.canHandle(request) }
    }

    /// The provider for a request; throws `noProvider` when nobody can serve it.
    public func provider(for request: AcquisitionRequest) throws -> any MediaProvider {
        guard let found = resolve(request) else { throw AcquisitionError.noProvider }
        return found
    }
}
