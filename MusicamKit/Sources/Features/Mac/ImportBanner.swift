#if os(macOS)
import SwiftUI

struct ImportBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.library.importState {
        case .idle:
            EmptyView()
        case .running(let done, let total, let name):
            HStack(spacing: 12) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 140)
                Text("Importing \(done) of \(total)")
                    .monospacedDigit()
                Text(name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .banner()
        case .finished(let summary):
            HStack(spacing: 12) {
                Image(systemName: summary.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.failed == 0 ? Color.green : Color.orange)
                Text(ImportState.message(for: summary))
                Spacer()
                Button("Dismiss", systemImage: "xmark.circle", action: app.library.dismissImportMessage)
                    .buttonStyle(.link)
            }
            .banner()
        }
    }
}

private extension View {
    func banner() -> some View {
        self
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}
#endif
