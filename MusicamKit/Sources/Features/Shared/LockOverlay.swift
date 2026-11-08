import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Covers the app while it is locked and asks the system to confirm the owner.
struct LockOverlay: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let lock = app.lock
        content
            .blur(radius: lock.isLocked ? 30 : 0)
            .allowsHitTesting(!lock.isLocked)
            .overlay {
                if lock.isLocked {
                    ZStack {
                        Rectangle().fill(.background).ignoresSafeArea()
                        VStack(spacing: 18) {
                            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(Theme.gradient)
                            Text("Musicam is locked").font(Theme.heading())
                            if let message = lock.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                            Button { Task { await lock.unlock() } } label: { Label("Unlock", systemImage: "faceid") }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                        }
                        .padding(32)
                    }
                    .transition(.opacity)
                    .task { await lock.unlock() }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                switch phase {
                case .background, .inactive: lock.appDidLeave()
                case .active: lock.appDidReturn(); if lock.isLocked { Task { await lock.unlock() } }
                @unknown default: break
                }
                #endif
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in lock.appDidLeave() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                lock.appDidReturn(); if lock.isLocked { Task { await lock.unlock() } }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in lock.lockNow() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in lock.lockNow() }
            #endif
    }
}

extension View {
    func appLock() -> some View { modifier(LockOverlay()) }
}
