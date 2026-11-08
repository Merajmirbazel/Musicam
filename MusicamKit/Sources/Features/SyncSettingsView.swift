import SwiftUI

/// Pair this device with another one and see whether they are in sync. Same screen on macOS and iOS.
struct SyncSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            if app.sync.isPaired {
                SyncPairedSection()
            } else {
                SyncStartSection()
            }
            if app.sync.isPaired { OfflineSection() }
            Section("How it works") {
                HowItWorksRow(symbol: "wifi", title: "Same Wi-Fi",
                              text: "Open Musicam on both devices while they are on the same network.")
                HowItWorksRow(symbol: "lock.shield.fill", title: "Private",
                              text: "Your devices talk directly to each other. Nothing is stored in the cloud.")
                HowItWorksRow(symbol: "arrow.triangle.2.circlepath", title: "Always the same library",
                              text: "Songs and changes appear on both. A song's audio file is copied to a device the first time you play it there.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
        .reservesPlayerSpace()
    }
}

/// One step of the "How it works" card: a colored icon, a short title and a sentence.
private struct HowItWorksRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Theme.gradient, in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
