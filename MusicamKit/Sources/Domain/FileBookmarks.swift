import Foundation

/// Bookmark options that differ by platform: macOS needs security-scoped bookmarks to keep access to
/// user-chosen files inside the sandbox; iOS has no such option (picked files are copied into the app instead).
public enum FileBookmarks {
    #if os(macOS)
    public static let creation: URL.BookmarkCreationOptions = .withSecurityScope
    public static let resolution: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    public static let creation: URL.BookmarkCreationOptions = []
    public static let resolution: URL.BookmarkResolutionOptions = []
    #endif
}
