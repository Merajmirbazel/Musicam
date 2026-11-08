#if os(macOS)
import SwiftUI

/// Five stars. Clicking the current rating clears it.
struct RatingView: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button("\(star) stars", systemImage: star <= rating ? "star.fill" : "star") {
                    onChange(star == rating ? 0 : star)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(star <= rating ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating")
    }
}
#endif
