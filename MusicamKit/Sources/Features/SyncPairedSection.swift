import SwiftUI
import Peering

/// Shown once paired: who is connected, downloads in progress, the code to share, and how to unpair.
struct SyncPairedSection: View {
    @Environment(AppModel.self) private var app
    #if DEBUG
    @State private var showCode = UserDefaults.standard.bool(forKey: "MusicamShowCode")   // debug launch flag, so tests can see the QR code
    #else
    @State private var showCode = false
    #endif

    var body: some View {
        let sync = app.sync
        Section("Status") {
            Label(sync.status, systemImage: sync.peers.isEmpty ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill")
                .foregroundStyle(sync.peers.isEmpty ? Color.secondary : Color.green)
            ForEach(sync.peers) { peer in
                Label(peer.name, systemImage: "laptopcomputer.and.iphone")
            }
            ForEach(sync.downloads.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                ProgressView(value: sync.downloads[id] ?? 0) { Text("Copying a song from your other device") }
            }
            if let problem = sync.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        Section("Pairing code") {
            if showCode, let code = sync.pairingCode {
                if let key = PairingKey(code: code) {
                    PairingQRView(text: key.pairingLink)
                    Text("Scan this with Musicam on your other device, or enter the code below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            Toggle(isOn: $showCode) { Label("Show code", systemImage: "eye") }
            if let code = sync.pairingCode {
                ShareLink(item: code) { Label("Share code", systemImage: "square.and.arrow.up") }
            }
            Text("Treat this code like a password: anyone who has it can sync with your library while on your network.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Button("Forget this pairing", systemImage: "link.badge.minus", role: .destructive, action: unpair)
        }
    }

    private func unpair() {
        Task { await app.sync.unpair() }
    }
}
