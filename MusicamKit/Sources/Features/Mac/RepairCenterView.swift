#if os(macOS)
import SwiftUI
import Domain
import Metadata

/// Suggestions to tidy song details: each shows what it is now and what it would become, and nothing changes until you accept.
struct RepairCenterView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<TrackID>()
    @State private var lookupTask: Task<Void, Never>?

    var body: some View {
        let repair = app.repair
        List {
            Section {
                summary(repair)
            }
            if !repair.proposals.isEmpty {
                Section("Suggestions (\(repair.proposals.count))") {
                    ForEach(repair.proposals) { p in
                        ProposalRow(proposal: p, selected: selection.contains(p.trackID)) {
                            if selection.contains(p.trackID) { selection.remove(p.trackID) } else { selection.insert(p.trackID) }
                        }
                    }
                }
            }
            MissingDetailsSection(tracks: repair.missingDetails)
            if !repair.duplicates.isEmpty {
                Section("Possible duplicates (\(repair.duplicates.count))") {
                    ForEach(Array(repair.duplicates.enumerated()), id: \.offset) { _, group in
                        DuplicateRow(group: group)
                    }
                }
            }
            if !repair.history.isEmpty {
                Section("Applied repairs") {
                    ForEach(repair.history.prefix(30)) { record in
                        HistoryRow(record: record)
                    }
                }
            }
        }
        .navigationTitle("Repair Center")
        .task { await repair.scan() }
        .toolbar {
            ToolbarItemGroup {
                Button("Apply Selected", systemImage: "checkmark") {
                    let ids = selection
                    selection = []
                    Task { await repair.apply(ids) }
                }
                .disabled(selection.isEmpty)
                Button("Apply All Safe", systemImage: "checkmark.seal") {
                    Task { await repair.applySafe() }
                }
                .disabled(repair.safeProposals.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func summary(_ repair: RepairModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if repair.issueCounts.isEmpty {
                Label("Everything looks tidy.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                ForEach(repair.issueCounts.sorted { $0.value > $1.value }, id: \.key) { key, count in
                    HStack { Text(key); Spacer(); Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                }
            }
            Divider()
            HStack {
                if repair.isLookingUp, let p = repair.lookupProgress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Button("Stop", systemImage: "stop.fill") { lookupTask?.cancel() }
                } else {
                    Button("Look Up Missing Details Online", systemImage: "globe") {
                        lookupTask = Task { await repair.lookUpOnline() }
                    }
                    .disabled(repair.isLookingUp)
                }
            }
            if let m = repair.lookupMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
            Text("Online lookup sends only a song’s title and artist to Deezer and Apple Music search, about one song every few seconds. Changes are saved in Musicam, not inside your files.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProposalRow: View {
    @Environment(AppModel.self) private var app
    let proposal: RepairProposal
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(proposal.changes, id: \.field) { c in
                    HStack(spacing: 6) {
                        Text(c.field == .artwork ? LocalizedStringKey("cover") : LocalizedStringKey(c.field.rawValue)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        if c.field == .artwork {
                            Text("none").foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption2)
                            ArtworkView(key: c.after, seed: proposal.trackID).frame(width: 36, height: 36)
                        } else {
                            Text(c.before.isEmpty ? "—" : c.before).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption2)
                            Text(c.after).bold()
                        }
                    }
                }
            }
            Spacer()
            Text(proposal.isSafe ? LocalizedStringKey("Safe") : LocalizedStringKey("Check"))
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(proposal.isSafe ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
            if let t = app.library.track(id: proposal.trackID) { WebSearchMenu(title: t.title, artist: t.artist).labelStyle(.iconOnly) }
            Button("Skip", systemImage: "forward.end") { Task { await app.repair.skip(proposal.trackID) } }
        }
        .padding(.vertical, 2)
    }
}

private struct DuplicateRow: View {
    @Environment(AppModel.self) private var app
    let group: [Track]

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                ForEach(Array(group.enumerated()), id: \.element.id) { i, t in
                    Text("\(i == 0 ? String(localized: "Keep") : String(localized: "Remove")) · \(t.title) — \(t.artist) · \(t.file?.format.summary ?? String(localized: "no file"))")
                        .foregroundStyle(i == 0 ? .primary : .secondary)
                }
            }
            Spacer()
            Button("Remove Extra Copies", systemImage: "trash") { Task { await app.repair.removeDuplicates(inGroup: group) } }
        }
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var app
    let record: RepairRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(record.changes.map { $0.field == .artwork ? String(localized: "cover added") : "\($0.before) → \($0.after)" }.joined(separator: " · ")).lineLimit(1)
                Text(record.appliedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if record.undoneAt == nil {
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await app.repair.undo(record) } }
            } else {
                Text("Undone").foregroundStyle(.secondary)
            }
        }
    }
}
#endif
