import SwiftUI

/// Shown until this device is paired: create a code here, or enter the one made on the other device.
struct SyncStartSection: View {
    @Environment(AppModel.self) private var app
    @State private var code = ""
    @State private var scanning = false

    var body: some View {
        Section("Pair with another device") {
            Text("Start on the first device: create a code. Then enter that code on the second device.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Create a pairing code", systemImage: "link", action: createCode)
        }
        .sheet(isPresented: $scanning) {
            #if os(iOS)
            QRScanSheet()
            #endif
        }
        #if os(iOS)
        Section("Scan") {
            Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
        }
        #endif
        Section("I already have a code") {
            TextField("Paste the code from your other device", text: $code, axis: .vertical)
                .lineLimit(2...4)
                .autocorrectionDisabled()
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    code = strings.first ?? code
                }
                Spacer()
                Button("Join", systemImage: "link", action: join)
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = app.sync.joinError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func createCode() {
        Task { await app.sync.createPairing() }
    }

    private func join() {
        let entered = code
        Task { await app.sync.join(code: entered) }
    }
}
