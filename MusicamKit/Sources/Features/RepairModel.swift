import Foundation
import Observation
import Domain
import Importing
import Metadata

/// What the Repair Center shows and does. Suggestions are only ever applied when the person says so,
/// and every applied repair can be taken back.
@MainActor
@Observable
public final class RepairModel {
    public private(set) var proposals: [RepairProposal] = []
    public private(set) var duplicates: [[Track]] = []
    public private(set) var history: [RepairRecord] = []
    public private(set) var issueCounts: [String: Int] = [:]
    /// Songs that still lack an artist, album or cover and have no suggestion yet: the person can look them up on the web.
    public private(set) var missingDetails: [Track] = []
    public private(set) var isLookingUp = false
    public private(set) var lookupProgress: (done: Int, total: Int)?
    public private(set) var lookupMessage: String?

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let log: RepairHistory
    @ObservationIgnored private let lookup: (any RecordingLookup)?
    @ObservationIgnored private let artworkStore: ArtworkStore?
    @ObservationIgnored private let cover: (@Sendable (String) async -> Data?)?
    @ObservationIgnored private var skipped = Set<TrackID>()
    @ObservationIgnored private var onlineProposals: [TrackID: RepairProposal] = [:]
    /// Offers the same ten-second Undo as every other action.
    @ObservationIgnored public var undoCenter: UndoCenter?

    public init(library: LibraryModel, historyURL: URL?, lookup: (any RecordingLookup)? = nil,
                artworkStore: ArtworkStore? = nil, cover: (@Sendable (String) async -> Data?)? = nil) {
        self.artworkStore = artworkStore
        self.cover = cover
        self.library = library
        self.log = RepairHistory(url: historyURL)
        self.lookup = lookup
    }

    public var safeProposals: [RepairProposal] { proposals.filter(\.isSafe) }

    /// Looks through the whole library using the built-in rules (instant, offline).
    public func scan() async {
        let tracks = library.tracks
        var counts: [String: Int] = [:]
        for t in tracks {
            for issue in TagSanity.issues(for: t) { counts[Self.label(issue), default: 0] += 1 }
        }
        issueCounts = counts
        var all = RepairPlanner.proposals(for: tracks)
        let ruleIDs = Set(all.map(\.trackID))
        all.append(contentsOf: onlineProposals.values.filter { !ruleIDs.contains($0.trackID) })
        proposals = all.filter { !skipped.contains($0.trackID) }
            .sorted { ($0.confidence, library.track(id: $0.trackID)?.title ?? "") > ($1.confidence, library.track(id: $1.trackID)?.title ?? "") }
        duplicates = TagSanity.duplicateGroups(in: tracks)
        let suggested = Set(proposals.map(\.trackID))
        missingDetails = Array(tracks.filter { !suggested.contains($0.id) && !$0.title.isEmpty && ($0.artist.isEmpty || $0.album.isEmpty) }.prefix(40))
        // an applied repair is listed only while it can still be undone (ten seconds), then it is forgotten
        if undoCenter != nil { await log.purge(appliedBefore: Date().addingTimeInterval(-UndoCenter.window - 1)) }
        history = await log.all()
    }

    public func apply(_ ids: Set<TrackID>) async {
        var records: [RepairRecord] = []
        for p in proposals where ids.contains(p.trackID) {
            await library.edit(p.trackID, p.edit)
            records.append(await log.record(p))
        }
        if !records.isEmpty {
            undoCenter?.register(records.count == 1 ? String(localized: "Applied 1 repair") : String(localized: "Applied \(records.count) repairs"),
                                 undo: { [weak self] in for r in records { await self?.undo(r) } },
                                 expire: { [weak self] in await self?.forget(Set(records.map(\.id))) })
        }
        onlineProposals = onlineProposals.filter { !ids.contains($0.key) }
        await scan()
    }

    private func forget(_ ids: Set<UUID>) async {
        await log.remove(ids: ids)
        history = await log.all()
    }

    public func applySafe() async { await apply(Set(safeProposals.map(\.trackID))) }

    public func skip(_ id: TrackID) async {
        skipped.insert(id)
        await scan()
    }

    public func undo(_ record: RepairRecord) async {
        guard record.undoneAt == nil else { return }
        await library.edit(record.trackID, record.undoEdit)
        await log.markUndone(record.id)
        await scan()
    }

    /// Asks the public Deezer and Apple Music search for songs that are missing details. The person can stop it.
    public func lookUpOnline() async {
        guard let lookup, !isLookingUp else { return }
        let candidates = library.tracks.filter { !$0.title.isEmpty && ($0.artist.isEmpty || $0.album.isEmpty || ($0.artworkKey == nil && cover != nil)) }
        guard !candidates.isEmpty else { lookupMessage = String(localized: "Nothing is missing details."); return }
        isLookingUp = true
        lookupMessage = nil
        var failures = 0
        for (i, track) in candidates.enumerated() {
            if Task.isCancelled { break }
            lookupProgress = (i, candidates.count)
            do {
                let matches = try await lookup.search(title: track.title, artist: track.artist.isEmpty ? nil : track.artist)
                var proposal = MusicBrainzPlanner.proposal(for: track, matches: matches)
                if track.artworkKey == nil, let cover, let store = artworkStore,
                   let release = MusicBrainzPlanner.coverRelease(for: track, matches: matches),
                   let data = await cover(release), let key = store.save(data) {
                    let change = FieldChange(field: .artwork, before: "", after: key, reason: .fromMusicBrainz)
                    if proposal != nil { proposal?.changes.append(change) }
                    else { proposal = RepairProposal(trackID: track.id, changes: [change], confidence: 0.9) }
                }
                if let proposal { onlineProposals[track.id] = proposal }
            } catch {
                failures += 1
                if failures >= 3 { lookupMessage = String(localized: "Could not reach the online music catalogs. Check the connection and try again."); break }
            }
        }
        lookupProgress = nil
        isLookingUp = false
        if lookupMessage == nil { lookupMessage = String(localized: "Found \(onlineProposals.count) suggestions.") }
        await scan()
    }

    /// Moves duplicate songs to the removed list, keeping the best one in each group.
    public func removeDuplicates(inGroup group: [Track]) async {
        guard group.count > 1 else { return }
        await library.remove(Set(group.dropFirst().map(\.id)))
        await scan()
    }

    static func label(_ issue: TagIssue) -> String {
        switch issue {
        case .missingArtist: String(localized: "No artist")
        case .missingAlbum: String(localized: "No album")
        case .missingTitle: String(localized: "No title")
        case .titleLooksLikeFilename: String(localized: "Title is a file name")
        case .genericTitle: String(localized: "Generic title")
        case .junkInText: String(localized: "Site names or tags in text")
        case .garbledText: String(localized: "Garbled text")
        case .noArtwork: String(localized: "No cover")
        case .suspiciousYear: String(localized: "Odd year")
        }
    }
}
