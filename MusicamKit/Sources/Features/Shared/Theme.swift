import SwiftUI

/// One look for both platforms: a violet-to-pink accent, rounded headings, generous spacing, soft cards.
enum Theme {
    static let accent = Color(red: 0.49, green: 0.36, blue: 1.0)
    static let accent2 = Color(red: 0.93, green: 0.33, blue: 0.66)
    static var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing) }

    static let spacing: CGFloat = 16
    static let corner: CGFloat = 14
    static let cardWidth: CGFloat = 148

    static func heading() -> Font { .system(.title2, design: .rounded, weight: .bold) }
    static func sectionTitle() -> Font { .system(.title3, design: .rounded, weight: .bold) }
}

extension View {
    /// A soft rounded card surface.
    func cardBackground() -> some View {
        background(.background.secondary, in: .rect(cornerRadius: Theme.corner))
    }
}

extension View {
    /// Pushed screens sit under the floating mini player on iPhone; this leaves room at the bottom so nothing is hidden behind it.
    func reservesPlayerSpace() -> some View { modifier(ReservesPlayerSpace()) }
}

private struct ReservesPlayerSpace: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        #if os(iOS)
        content.safeAreaPadding(.bottom, app.playback.current == nil || app.isSelectingSongs ? 0 : 72)
        #else
        content
        #endif
    }
}
