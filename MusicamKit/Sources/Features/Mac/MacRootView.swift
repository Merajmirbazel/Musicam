#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The macOS main window: sidebar, content, and the player bar pinned to the bottom.
public struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @State private var isDropTargeted = false

    public init() {}

    public var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailContainer()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar() }
        .sheet(isPresented: $app.showLinkSheet) { AddLinkSheet() }
        .fileImporter(isPresented: $app.showImporter, allowedContentTypes: [.audio, .folder],
                      allowsMultipleSelection: true, onCompletion: app.importerFinished)
        .dropDestination(for: URL.self, action: { urls, _ in app.handleDrop(urls) }, isTargeted: { isDropTargeted = $0 })
        .overlay { if isDropTargeted { DropHighlight() } }
        .appLock()
        .task { await app.start() }
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: 12))
            .padding(8)
            .allowsHitTesting(false)
    }
}
#endif
