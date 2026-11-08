import SwiftUI

/// Paste a link: Spotify or YouTube links go to the wishlist (name only), or a Spotify link is downloaded through Merajfy when it is turned on; a direct link to an audio file is downloaded.
struct AddLinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: LocalizedStringKey?
    @State private var messageText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste a link", text: $text, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabledCompat()
                    Button("Add", systemImage: "plus.circle.fill", action: submit)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || app.wishlist.isWorking)
                    if app.wishlist.isWorking { ProgressView() }
                    if let messageText { Text(messageText).foregroundStyle(.secondary) }
                } footer: {
                    Text("Spotify and YouTube links are added to your Wishlist by name only. If Merajfy is turned on in Settings, a Spotify track, album or playlist link is downloaded and added to your library instead. A direct link to an audio file you are allowed to download, such as one from the Internet Archive, is downloaded and added to your library.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add from Link")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
        // a link sent from the share sheet is added right away
        .task {
            if let link = app.pendingLink {
                app.pendingLink = nil
                text = link
                submit()
            }
        }
    }

    private func submit() {
        let value = text
        Task {
            let outcome = await app.wishlist.submit(value)
            switch outcome {
            case .wishlisted(let title): messageText = String(localized: "Added “\(title)” to your Wishlist."); text = ""
            case .alreadyListed: messageText = String(localized: "That link is already on your Wishlist.")
            case .imported(let name): messageText = String(localized: "Downloaded “\(name)” and added it to your library."); text = ""
            case .unsupported(let host): messageText = String(localized: "Musicam cannot take audio from \(host). Add the song to your Wishlist from its Spotify or YouTube link, then add the file when you have it.")
            case .failed(let reason): messageText = reason
            }
        }
    }
}

private extension View {
    @ViewBuilder func autocorrectionDisabledCompat() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
