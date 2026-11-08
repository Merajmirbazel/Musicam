import SwiftUI

/// Elapsed time, a draggable position slider, and the total. Dragging never fights the playback clock.
struct ScrubberView: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var value: Double = 0
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(value))
                .frame(width: 46, alignment: .trailing)
            Slider(value: $value, in: 0...max(duration, 1), onEditingChanged: editingChanged)
                .controlSize(.small)
                .disabled(duration <= 0)
                .accessibilityLabel("Playback position")
            Text(formatTime(duration))
                .frame(width: 46, alignment: .leading)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .onAppear { value = elapsed }
        .onChange(of: elapsed) { _, new in
            if !isDragging { value = new }
        }
    }

    private func editingChanged(_ editing: Bool) {
        isDragging = editing
        if !editing { onSeek(value) }
    }
}
