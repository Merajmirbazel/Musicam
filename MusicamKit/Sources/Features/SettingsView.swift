import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings shared by both apps: the app lock, offline songs and the paired device.
public struct SettingsView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        Form {
            LibraryStatsSection()
            LanguageSection()
            LockSection()
            MerajfySection()
            if app.sync.isPaired { OfflineSection() }
            Section {
                NavigationLink { SyncSettingsView() } label: { Label("Devices", systemImage: "arrow.triangle.2.circlepath") }
                NavigationLink { WishlistView() } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                NavigationLink { repairScreen } label: { Label("Repair Center", systemImage: "wand.and.stars") }
            }
            Section("About") {
                LabeledContent("Musicam", value: "by Meraj Mirbazel")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .reservesPlayerSpace()
    }

    @ViewBuilder private var repairScreen: some View {
        #if os(iOS)
        IOSRepairView()
        #else
        RepairCenterView()
        #endif
    }
}

/// How much music there is in total: songs, listening time and playlists.
struct LibraryStatsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let library = app.library
        Section("Your Library") {
            LabeledContent { Text("\(library.tracks.count)").monospacedDigit() } label: { Label("Songs", systemImage: "music.note") }
            LabeledContent { Text(formatLongDuration(library.totalDuration)).monospacedDigit() } label: { Label("Total time", systemImage: "clock") }
            LabeledContent { Text("\(app.playlists.playlists.count)").monospacedDigit() } label: { Label("Playlists", systemImage: "music.note.list") }
        }
    }
}

struct LockSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var lock = app.lock
        Section {
            Toggle(isOn: Binding(get: { lock.isEnabled }, set: { on in Task { await lock.setEnabled(on) } })) {
                Label("Lock Musicam", systemImage: "lock.fill")
            }
            if lock.isEnabled {
                Picker(selection: $lock.delay) {
                    Text("Immediately").tag(AppLockModel.Delay.immediately)
                    Text("After 1 minute").tag(AppLockModel.Delay.oneMinute)
                    Text("After 5 minutes").tag(AppLockModel.Delay.fiveMinutes)
                } label: { Label("Ask again", systemImage: "timer") }
            }
            if let message = lock.message { Text(message).font(.footnote).foregroundStyle(.orange) }
        } header: {
            Text("Security")
        } footer: {
            Text("Musicam asks for Face ID, Touch ID or your passcode when it opens and when you come back to it. Music keeps playing while it is locked.")
        }
    }
}

/// Lets the person pick English or Persian without leaving the app. The choice is written to the app's own
/// language list, which the system reads at launch, so it takes effect after the app is reopened.
struct LanguageSection: View {
    private static let key = "musicam.language"
    @State private var choice = UserDefaults.standard.string(forKey: LanguageSection.key) ?? "system"
    /// The language the app was started in, to tell whether a restart is still needed.
    private let running = Bundle.main.preferredLocalizations.first ?? "en"

    private var needsRestart: Bool {
        let wanted = choice == "system" ? String((Locale.preferredLanguages.first ?? "en").prefix(2)) : choice
        return !running.hasPrefix(wanted)
    }

    var body: some View {
        Section {
            Picker(selection: $choice) {
                Text("Follow System").tag("system")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "فارسی").tag("fa")
            } label: {
                Label("Language", systemImage: "globe")
            }
            .onChange(of: choice) { _, new in apply(new) }
            if needsRestart {
                Text("Reopen Musicam to finish changing the language.").font(.callout).foregroundStyle(.secondary)
                #if os(macOS)
                Button("Quit Musicam", systemImage: "power") { NSApplication.shared.terminate(nil) }
                #endif
            }
        }
    }

    private func apply(_ value: String) {
        let d = UserDefaults.standard
        if value == "system" {
            d.removeObject(forKey: Self.key)
            d.removeObject(forKey: "AppleLanguages")
        } else {
            d.set(value, forKey: Self.key)
            d.set([value], forKey: "AppleLanguages")
        }
    }
}
