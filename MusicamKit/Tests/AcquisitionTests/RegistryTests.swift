import Testing
import Foundation
@testable import Acquisition

@Suite struct RegistryTests {
    private func provider(_ id: String, accepts: @escaping @Sendable (AcquisitionRequest) -> Bool = { _ in true }) -> FakeProvider {
        FakeProvider(id: id, accepts: accepts)
    }

    @Test func firstRegisteredProviderThatAcceptsWins() throws {
        let registry = ProviderRegistry()
        try registry.register(provider("a", accepts: { $0.url?.host == "a.example" }))
        try registry.register(provider("b"))
        #expect(try registry.provider(for: AcquisitionRequest(url: URL(string: "https://a.example/x")!)).id == "a")
        #expect(try registry.provider(for: AcquisitionRequest(url: URL(string: "https://other.example/x")!)).id == "b")
        #expect(registry.providers.map(\.id) == ["a", "b"])
    }

    @Test func aSecondProviderWithTheSameIdIsRefused() throws {
        let registry = ProviderRegistry()
        try registry.register(provider("a"))
        #expect(throws: AcquisitionError.duplicateProvider("a")) { try registry.register(provider("a")) }
        #expect(registry.providers.count == 1)
        #expect(throws: AcquisitionError.duplicateProvider("x")) { _ = try ProviderRegistry([provider("x"), provider("x")]) }
    }

    @Test func noMatchingProviderIsAnError() throws {
        let registry = try ProviderRegistry([provider("a", accepts: { _ in false })])
        #expect(registry.resolve(AcquisitionRequest(query: "x")) == nil)
        #expect(throws: AcquisitionError.noProvider) { _ = try registry.provider(for: AcquisitionRequest(query: "x")) }
        #expect(throws: AcquisitionError.noProvider) { _ = try ProviderRegistry().provider(for: AcquisitionRequest(query: "x")) }
    }

    @Test func providersCanBeRemovedAndLookedUp() throws {
        let registry = try ProviderRegistry([provider("a"), provider("b")])
        #expect(registry.provider(withID: "b")?.id == "b")
        #expect(registry.unregister(id: "a"))
        #expect(!registry.unregister(id: "a"))
        #expect(registry.providers.map(\.id) == ["b"])
    }

    @Test func requestsKnowWhenTheyAreEmpty() {
        #expect(AcquisitionRequest().isEmpty)
        #expect(AcquisitionRequest(query: "   ").isEmpty)
        #expect(!AcquisitionRequest(query: "song").isEmpty)
        #expect(!AcquisitionRequest.link(URL(string: "https://a.example/s.mp3")!).isEmpty)
    }

    @Test func standardRegistryPutsInternetArchiveBeforeDirectAudio() {
        let registry = ProviderRegistry.standard(downloadsDirectory: makeScratchFolder())
        #expect(registry.providers.map(\.id) == ["internet-archive", "direct-audio"])
        let archive = AcquisitionRequest.link(URL(string: "https://archive.org/download/x/a.mp3")!)
        let direct = AcquisitionRequest.link(URL(string: "https://example.org/a.mp3")!)
        let spotify = AcquisitionRequest.link(URL(string: "https://open.spotify.com/track/1")!)
        #expect(registry.resolve(archive)?.id == "internet-archive")
        #expect(registry.resolve(direct)?.id == "direct-audio")
        #expect(registry.resolve(spotify) == nil)                     // a streaming page is not a file: nobody serves it
    }
}
