#if os(macOS)
import SwiftUI
import Domain

/// Read-only facts about the song's file.
struct FileInfoView: View {
    let track: Track
    var isStoredHere = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File").font(.caption).foregroundStyle(.secondary)
            if let file = track.file {
                row(String(localized: "Format"), file.format.summary)
                row(String(localized: "Size"), file.byteSize.formatted(.byteCount(style: .file)))
                row(String(localized: "Name"), file.originalFilename)
            }
            if let file = track.file {
                HStack(alignment: .firstTextBaseline) {
                    Text("Source").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    SourceBadge(source: TrackSource(raw: file.source))
                }
            }
            row(String(localized: "Stored"), isStoredHere ? String(localized: "On this device") : String(localized: "Only on your other device"))
            row(String(localized: "Added"), track.addedAt.formatted(date: .abbreviated, time: .omitted))
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}
#endif
