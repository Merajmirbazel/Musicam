import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings for getting Spotify songs through Merajfy.
struct MerajfySection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var merajfy = app.merajfy
        Section {
            Toggle(isOn: $merajfy.isEnabled) { Label("Get Spotify songs with Merajfy", systemImage: "arrow.down.circle") }
            if merajfy.isEnabled {
                #if os(macOS)
                Picker(selection: $merajfy.mode) {
                    Text("Built in to Musicam").tag(MerajfySettings.Mode.builtIn)
                    Text("Another Merajfy").tag(MerajfySettings.Mode.external)
                } label: { Label("Downloader", systemImage: "shippingbox") }
                if merajfy.mode == .builtIn {
                    builtInStatus(merajfy)
                    Toggle(isOn: $merajfy.shareWithIPhone) { Label("Share with my iPhone", systemImage: "iphone.gen3") }
                    if merajfy.shareWithIPhone {
                        LabeledContent("iPhone address") { Text(merajfy.iPhoneAddress).textSelection(.enabled) }
                        LabeledContent("Token") { Text(merajfy.lanToken).textSelection(.enabled) }
                    }
                } else {
                    externalFields(merajfy)
                }
                #else
                if merajfy.onDeviceAvailable {
                    Picker(selection: $merajfy.mode) {
                        Text("On this iPhone").tag(MerajfySettings.Mode.builtIn)
                        Text("On my Mac").tag(MerajfySettings.Mode.external)
                    } label: { Label("Downloader", systemImage: "shippingbox") }
                }
                if merajfy.mode == .external || !merajfy.onDeviceAvailable { externalFields(merajfy) }
                #endif
                if !(merajfy.onDeviceAvailable && merajfy.mode == .builtIn) {
                    Picker(selection: $merajfy.format) {
                        ForEach(MerajfySettings.formats, id: \.self) { Text($0.uppercased()).tag($0) }
                    } label: { Label("File format", systemImage: "waveform") }
                } else {
                    LabeledContent("File format") { Text("M4A (AAC)") }
                }
                HStack {
                    Button("Test Connection", systemImage: "bolt.horizontal") { Task { await merajfy.testConnection() } }
                    #if os(macOS)
                    if merajfy.mode == .external {
                        Button("Open Merajfy", systemImage: "arrow.up.forward.app") {
                            if let url = URL(string: "merajfy://") { NSWorkspace.shared.open(url) }
                        }
                    }
                    #endif
                }
                switch merajfy.status {
                case .idle: EmptyView()
                case .testing: ProgressView()
                case .ok(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let text): Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Spotify Downloads")
        } footer: {
            #if os(macOS)
            Text("With this on, a Spotify track, album or playlist link in Add from Link is downloaded and added to your library. With it off, those links are only added to your Wishlist by name. Built in means Musicam runs the downloader itself on this Mac; to use it from your iPhone, turn on Share with my iPhone and type the address and token on the iPhone.")
            #else
            if merajfy.onDeviceAvailable && merajfy.mode == .builtIn {
                Text("With this on, a Spotify track, album or playlist link in Add from Link is downloaded on this iPhone and added to your library. Nothing needs to run on your Mac. With it off, those links are only added to your Wishlist by name. The first song of a session takes a few seconds longer while the downloader starts.")
            } else {
            Text("Merajfy is a separate program that runs on your Mac. With this on, a Spotify track, album or playlist link in Add from Link is downloaded and added to your library. With it off, those links are only added to your Wishlist by name. On the iPhone use your Mac's address and the token shown in Musicam's or Merajfy's settings on the Mac.")
            }
            #endif
        }
    }

    @ViewBuilder private func externalFields(_ merajfy: MerajfySettings) -> some View {
        @Bindable var merajfy = merajfy
        TextField("Mac address", text: $merajfy.address, prompt: Text(verbatim: "192.168.1.20:8787"))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
        SecureField("Token", text: $merajfy.token)
    }

    #if os(macOS)
    @ViewBuilder private func builtInStatus(_ merajfy: MerajfySettings) -> some View {
        switch merajfy.embedded.state {
        case .unavailable(let text): Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stopped: Label("Not running yet", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .starting: HStack { ProgressView().controlSize(.small); Text("Starting…") }
        case .running: Label("Downloader is running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text): Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
    #endif
}
