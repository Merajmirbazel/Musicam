import Testing
import Foundation
import Domain
import Importing
import Persistence
@testable import Acquisition

/// The finished file must go through the real importer, the same one the file picker uses: no second import path.
@MainActor
@Suite struct ImportHandoffTests {
    private func service(_ root: URL) throws -> (ImportService, LibraryStore) {
        let library = try LibraryStore.open(at: nil)
        let device = try DeviceStore.open(at: nil)
        return (ImportService(library: library, device: device, artwork: ArtworkStore(directory: root.appendingPathComponent("art"))), library)
    }

    @Test func anAcquiredSongEndsUpInTheLibraryWithItsSource() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let (importer, library) = try service(root)
        let wav = root.appendingPathComponent("Night Drive.wav")
        try writeWAV(at: wav)
        let provider = FakeProvider(id: "p") { _, _ in [AcquiredFile(url: wav, source: "link:example.org", providerID: "p")] }
        let m = AcquisitionManager(registry: try ProviderRegistry([provider]), handoff: ImportHandoff.importService(importer))
        let job = await m.perform(.link(URL(string: "https://example.org/Night%20Drive.wav")!))
        #expect(job.state == .finished(files: 1))
        let tracks = try await library.allTracks()
        #expect(tracks.count == 1)
        #expect(tracks.first?.title == "Night Drive")
        #expect(tracks.first?.file?.source == "link:example.org")
    }

    @Test func downloadingTheSameSongTwiceDoesNotDuplicateIt() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let (importer, library) = try service(root)
        let wav = root.appendingPathComponent("Same.wav")
        try writeWAV(at: wav)
        let provider = FakeProvider(id: "p") { _, _ in [AcquiredFile(url: wav, source: "link:example.org", providerID: "p")] }
        let m = AcquisitionManager(registry: try ProviderRegistry([provider]), handoff: ImportHandoff.importService(importer))
        _ = await m.perform(AcquisitionRequest(query: "one"))
        let again = await m.perform(AcquisitionRequest(query: "two"))
        #expect(again.state == .finished(files: 1))
        #expect(try await library.allTracks().count == 1)
    }

    @Test func aFileTheImporterCannotReadFailsTheRequest() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let (importer, library) = try service(root)
        let broken = makeAcquiredFile(in: root, name: "broken.mp3", bytes: Data("not really audio".utf8))
        let provider = FakeProvider(id: "p") { _, _ in [broken] }
        let m = AcquisitionManager(registry: try ProviderRegistry([provider]), handoff: ImportHandoff.importService(importer))
        let job = await m.perform(AcquisitionRequest(query: "x"))
        guard case .failed(.noUsableFiles) = job.state else { Issue.record("expected noUsableFiles, got \(job.state)"); return }
        #expect(try await library.allTracks().isEmpty)
    }
}
