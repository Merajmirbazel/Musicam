import SwiftUI

/// The "Undo" strip that appears after a removal and counts down the ten seconds. Same on macOS and iOS.
struct UndoBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let item = app.undo.current {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.title3).foregroundStyle(.secondary)
                Text(item.message).lineLimit(2).font(.callout)
                Spacer(minLength: 8)
                Button { Task { await app.undo.perform() } } label: {
                    HStack(spacing: 6) {
                        CountdownRing(deadline: item.deadline, duration: item.duration).frame(width: 18, height: 18)
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                Button("Dismiss", systemImage: "xmark") { app.undo.dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(item.id)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct CountdownRing: View {
    let deadline: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let left = max(0, deadline.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(.white.opacity(0.35), lineWidth: 2.5)
                Circle().trim(from: 0, to: left / max(duration, 0.1)).stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Shows the Undo strip at the bottom of the screen.
    func undoBanner() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            UndoBanner().padding(.bottom, 6).animation(.spring(duration: 0.3), value: true)
        }
    }
}
