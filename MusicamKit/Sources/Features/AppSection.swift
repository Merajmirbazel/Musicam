import Domain

/// The places a person can be in the main window.
public enum AppSection: Hashable, Sendable {
    case home
    case songs
    /// Songs marked with the heart.
    case favorites
    /// Pairing and sync status.
    case devices
    /// Folders watched for new music (macOS).
    case folders
    /// A playlist the person made.
    case playlist(PlaylistID)
    /// Songs remembered from links.
    case wishlist
    /// Suggestions for tidying song details.
    case repair
    /// Reached from the player bar, not listed in the sidebar.
    case nowPlaying
}
