import Testing
import Foundation
import Domain
import Sync
@testable import Persistence

private func item(_ title: String, hash: String? = nil, artist: String = "Artist") -> ImportedItem {
    ImportedItem(
        metadata: ExtractedMetadata(title: title, artist: artist, album: "Album", year: 2020, genre: "Rock", duration: 200,
                                    format: AudioFormat(codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2, isLossless: true),
                                    artworkKey: "art-\(title)"),
        contentHash: hash ?? UUID().uuidString, byteSize: 5_000, originalFilename: title + ".flac")
}

/// One full exchange, as the network layer performs it: each side sends what the other lacks.
private func exchange(_ a: LibraryStore, _ b: LibraryStore) async throws {
    let va = try await a.versionVector(), vb = try await b.versionVector()
    let toB = try await a.changes(missingFrom: vb)
    let toA = try await b.changes(missingFrom: va)
    try await b.ingest(toB)
    try await a.ingest(toA)
}

private func state(_ s: LibraryStore) async throws -> [Track] {
    try await s.allTracks().sorted { $0.id.uuidString < $1.id.uuidString }
}

@Suite struct SyncIntegrationTests {
    @Test func aNewDeviceReceivesTheWholeLibraryIdentically() async throws {
        let mac = try LibraryStore.open(at: nil), phone = try LibraryStore.open(at: nil)
        try await mac.add([item("One"), item("Two"), item("Three")])
        try await exchange(mac, phone)
        let a = try await state(mac), b = try await state(phone)
        #expect(b.count == 3)
        #expect(a == b)                                   // every field, the file descriptor and its ID included
        #expect(b.allSatisfy { $0.file?.format.summary == "FLAC · 16-bit · 44.1 kHz" })
    }

    @Test func eachDeviceHasItsOwnPermanentIdentity() async throws {
        let one = try LibraryStore.open(at: nil), two = try LibraryStore.open(at: nil)
        #expect(try await one.deviceIdentity() != two.deviceIdentity())
        #expect(try await one.deviceIdentity() == one.deviceIdentity())
    }

    @Test func editsOnDifferentFieldsFromBothDevicesAreBothKept() async throws {
        let mac = try LibraryStore.open(at: nil), phone = try LibraryStore.open(at: nil)
        let id = try await mac.add([item("Song")])[0].trackID
        try await exchange(mac, phone)

        try await mac.edit(trackID: id, TrackEdit(artist: "New artist"))
        try await phone.edit(trackID: id, TrackEdit(album: "New album", rating: 4))
        try await exchange(mac, phone)

        for store in [mac, phone] {
            let t = try #require(try await store.track(id: id))
            #expect(t.artist == "New artist")
            #expect(t.album == "New album")
            #expect(t.rating == 4)
        }
    }

    @Test func whenBothEditTheSameFieldTheLaterEditWinsOnBothDevices() async throws {
        let mac = try LibraryStore.open(at: nil), phone = try LibraryStore.open(at: nil)
        let id = try await mac.add([item("Song")])[0].trackID
        try await exchange(mac, phone)

        try await mac.edit(trackID: id, TrackEdit(title: "Mac was first"))
        try await Task.sleep(for: .milliseconds(5))
        try await phone.edit(trackID: id, TrackEdit(title: "Phone was later"))
        try await exchange(mac, phone)

        #expect(try await mac.track(id: id)?.title == "Phone was later")
        #expect(try await phone.track(id: id)?.title == "Phone was later")
    }

    @Test func aDeletionTravelsAndAnEditAfterwardsDoesNotBringTheSongBack() async throws {
        let mac = try LibraryStore.open(at: nil), phone = try LibraryStore.open(at: nil)
        let id = try await mac.add([item("Doomed"), item("Stays")])[0].trackID
        try await exchange(mac, phone)

        try await mac.softDelete(trackIDs: [id])
        try await phone.edit(trackID: id, TrackEdit(title: "Edited while deleted elsewhere"))
        try await exchange(mac, phone)

        #expect(try await mac.trackCount() == 1)
        #expect(try await phone.trackCount() == 1)
        #expect(try await state(mac) == state(phone))
    }

    @Test func receivingTheSameChangesAgainChangesNothing() async throws {
        let mac = try LibraryStore.open(at: nil), phone = try LibraryStore.open(at: nil)
        try await mac.add([item("One"), item("Two")])
        let batch = try await mac.changes(missingFrom: VersionVector())
        let first = try await phone.ingest(batch)
        let again = try await phone.ingest(batch)
        #expect(first == batch.count)
        #expect(again == 0)
        #expect(try await phone.changeCount() == batch.count)
        #expect(try await phone.trackCount() == 2)
    }

    @Test func changesArrivingInAnyOrderGiveTheSameResult() async throws {
        let mac = try LibraryStore.open(at: nil)
        try await mac.add([item("One"), item("Two"), item("Three")])
        let id = try await mac.allTracks()[0].id
        try await mac.edit(trackID: id, TrackEdit(title: "Renamed", isFavorite: true))
        let batch = try await mac.changes(missingFrom: VersionVector())

        let ordered = try LibraryStore.open(at: nil), shuffled = try LibraryStore.open(at: nil)
        try await ordered.ingest(batch)
        var rng = SystemRandomNumberGenerator()
        try await shuffled.ingest(batch.shuffled(using: &rng))   // files may arrive before their tracks
        #expect(try await state(ordered) == state(mac))
        #expect(try await state(shuffled) == state(mac))
    }

    @Test func aConnectionThatDropsHalfwayResumesWithoutLossOrDuplicates() async throws {
        let mac = try LibraryStore.open(at: nil), phone = try LibraryStore.open(at: nil)
        try await mac.add((1...20).map { item("Song \($0)") })
        let all = try await mac.changes(missingFrom: try await phone.versionVector())
        try await phone.ingest(Array(all.prefix(all.count / 2)))       // dropped here

        let rest = try await mac.changes(missingFrom: try await phone.versionVector())
        try await phone.ingest(rest)
        #expect(try await phone.changeCount() == all.count)
        #expect(try await state(phone) == state(mac))
    }

    @Test func threeDevicesWithRandomWorkAndPartialSyncsConverge() async throws {
        for seed in 1...8 {
            var rng = SplitMix(seed: UInt64(seed))
            let stores = try (0..<3).map { _ in try LibraryStore.open(at: nil) }
            for step in 0..<40 {
                let s = stores[Int.random(in: 0..<3, using: &rng)]
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<3:
                    try await s.add([item("Song \(seed)-\(step)")])
                case 3..<6:
                    if let t = try await s.allTracks().randomElement(using: &rng) {
                        try await s.edit(trackID: t.id, TrackEdit(title: "T\(step)", artist: "A\(step % 3)", rating: step % 6))
                    }
                case 6:
                    if let t = try await s.allTracks().randomElement(using: &rng) { try await s.softDelete(trackIDs: [t.id]) }
                default:
                    // a partial exchange between two devices
                    let o = stores[Int.random(in: 0..<3, using: &rng)]
                    let missing = try await s.changes(missingFrom: try await o.versionVector())
                    try await o.ingest(Array(missing.prefix(Int.random(in: 0...missing.count, using: &rng))))
                }
            }
            for _ in 0..<2 {
                try await exchange(stores[0], stores[1]); try await exchange(stores[1], stores[2]); try await exchange(stores[0], stores[2])
            }
            let a = try await state(stores[0]), b = try await state(stores[1]), c = try await state(stores[2])
            #expect(a == b, "seed \(seed)")
            #expect(b == c, "seed \(seed)")
        }
    }

    @Test func theClockResumesAfterReopeningSoNewStampsNeverRepeat() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-clock-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.store")

        let id: TrackID
        let device: DeviceID
        do {
            let s = try LibraryStore.open(at: url)
            id = try await s.add([item("Song")])[0].trackID
            device = try await s.deviceIdentity()
        }
        let reopened = try LibraryStore.open(at: url)
        #expect(try await reopened.deviceIdentity() == device)
        try await reopened.edit(trackID: id, TrackEdit(title: "After reopening"))
        let all = try await reopened.changes(missingFrom: VersionVector())
        #expect(Set(all.map(\.stamp)).count == all.count)
        #expect(all.last?.field == "title")
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite struct LegacyLibraryTests {
    @Test func songsMadeBeforeSyncExistedGetJournalEntriesOnFirstUseAndReachAnotherDevice() async throws {
        let old = try LibraryStore.open(at: nil)
        for title in ["Old one", "Old two"] {
            try await old.insertLegacySongForTesting(ImportedItem(
                metadata: ExtractedMetadata(title: title, artist: "A", format: AudioFormat(codec: "MP3")),
                contentHash: UUID().uuidString, byteSize: 10, originalFilename: title + ".mp3"))
        }
        // first sync use creates the missing journal
        let fresh = try LibraryStore.open(at: nil)
        let batch = try await old.changes(missingFrom: VersionVector())
        #expect(!batch.isEmpty)
        try await fresh.ingest(batch)
        #expect(Set(try await fresh.allTracks().map(\.title)) == ["Old one", "Old two"])
        #expect(try await fresh.allTracks().allSatisfy { $0.file != nil })
        // and doing it again does not duplicate anything
        let again = try await old.changes(missingFrom: VersionVector())
        #expect(again.count == batch.count)
    }
}
