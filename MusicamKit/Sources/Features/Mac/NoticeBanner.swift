#if os(macOS)
import SwiftUI

/// A visible message when something could not be played, instead of a silent skip.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let notice = app.playback.notice {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(notice)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
#endif
