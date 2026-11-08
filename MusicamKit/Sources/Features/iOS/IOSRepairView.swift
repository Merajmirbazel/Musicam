#if os(iOS)
import SwiftUI
import Domain
import Metadata

/// Suggestions for tidying song details on the iPhone. Nothing changes until you accept, and every repair can be undone.
struct IOSRepairView: View {
    @Environment(AppModel.self) private var app
    @State private var lookupTask: Task<Void, Never>?

    var body: some View {
        let repair = app.repair
        List {
            Section {
                if repair.issueCounts.isEmpty {
                    Label("Everything looks tidy.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ForEach(repair.issueCounts.sorted { $0.value > $1.value }, id: \.key) { key, count in
                        LabeledContent(key, value: "\(count)")
                    }
                }
                if repair.isLookingUp, let p = repair.lookupProgress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Button("Stop", systemImage: "stop.fill") { lookupTask?.cancel() }
                } else {
                    Button("Look Up Missing Details Online", systemImage: "globe") {
                        lookupTask = Task { await repair.lookUpOnline() }
                    }
                }
                if let m = repair.lookupMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Online lookup sends only a song’s title and artist to Deezer and Apple Music search. Changes are saved in Musicam, not inside your files.")
            }
            if !repair.proposals.isEmpty {
                Section("Suggestions (\(repair.proposals.count))") {
                    ForEach(repair.proposals) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(p.changes, id: \.field) { c in
                                if c.field == .artwork {
                                    HStack { Text("Cover").font(.caption).foregroundStyle(.secondary)
                                        ArtworkView(key: c.after, seed: p.trackID).frame(width: 36, height: 36) }
                                } else {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(c.field.rawValue).font(.caption).foregroundStyle(.secondary)
                                        Text(c.before.isEmpty ? "—" : c.before).strikethrough().foregroundStyle(.secondary)
                                        Text(c.after).bold()
                                    }
                                }
                            }
                            HStack {
                                Button("Apply", systemImage: "checkmark") { Task { await repair.apply([p.trackID]) } }.buttonStyle(.borderedProminent)
                                Button("Skip", systemImage: "forward.end") { Task { await repair.skip(p.trackID) } }.buttonStyle(.bordered)
                                Spacer()
                                if let t = app.library.track(id: p.trackID) { WebSearchMenu(title: t.title, artist: t.artist).labelStyle(.iconOnly).buttonStyle(.bordered) }
                                Text(p.isSafe ? LocalizedStringKey("Safe") : LocalizedStringKey("Check")).font(.caption2).foregroundStyle(p.isSafe ? .green : .orange)
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            MissingDetailsSection(tracks: repair.missingDetails)
            if !repair.duplicates.isEmpty {
                Section("Possible duplicates (\(repair.duplicates.count))") {
                    ForEach(Array(repair.duplicates.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading) {
                            ForEach(Array(group.enumerated()), id: \.element.id) { i, t in
                                Text("\(i == 0 ? String(localized: "Keep") : String(localized: "Remove")) · \(t.title) · \(t.file?.format.summary ?? String(localized: "no file"))")
                                    .font(.footnote).foregroundStyle(i == 0 ? .primary : .secondary)
                            }
                            Button("Remove Extra Copies", systemImage: "trash") { Task { await repair.removeDuplicates(inGroup: group) } }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            if !repair.history.isEmpty {
                Section("Applied repairs") {
                    ForEach(repair.history.prefix(30)) { r in
                        HStack {
                            Text(r.changes.map { $0.field == .artwork ? String(localized: "cover added") : "\($0.before) → \($0.after)" }.joined(separator: " · ")).lineLimit(2).font(.footnote)
                            Spacer()
                            if r.undoneAt == nil { Button("Undo", systemImage: "arrow.uturn.backward") { Task { await repair.undo(r) } }.buttonStyle(.bordered).controlSize(.small) }
                            else { Text("Undone").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Repair")
        .reservesPlayerSpace()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Apply All Safe", systemImage: "checkmark.seal") { Task { await repair.applySafe() } }
                    .disabled(repair.safeProposals.isEmpty)
            }
        }
        .task { await repair.scan() }
    }
}
#endif
