import Foundation

/// Where a song's file came from. Stored as a short text on the file so it syncs and survives restarts.
/// Only what is actually known is recorded: a file picked by hand is "file", never a streaming service.
public enum TrackSource: Equatable, Sendable {
    case unknown                    // added by an older version, origin not recorded
    case file                       // picked in the file picker
    case folder                     // a whole folder picked in the file picker
    case watched                    // appeared in a watched folder
    case telegram                   // appeared in a watched folder that is Telegram's download folder
    case shared                     // handed over by another app ("Open in Musicam", Share Sheet)
    case link(host: String)         // downloaded from a direct link to an audio file

    public init(raw: String) {
        switch raw {
        case "": self = .unknown
        case "file": self = .file
        case "folder": self = .folder
        case "watched": self = .watched
        case "telegram": self = .telegram
        case "shared": self = .shared
        default:
            if raw.hasPrefix("link:") { self = .link(host: String(raw.dropFirst(5))) } else { self = .unknown }
        }
    }

    public var raw: String {
        switch self {
        case .unknown: ""
        case .file: "file"
        case .folder: "folder"
        case .watched: "watched"
        case .telegram: "telegram"
        case .shared: "shared"
        case .link(let host): "link:\(host)"
        }
    }

    /// True for songs that came to this library from the network or another app, as opposed to files the person picked.
    public var isDownloaded: Bool {
        switch self {
        case .watched, .telegram, .shared, .link: true
        default: false
        }
    }

    /// The raw value to store for a folder that is being watched.
    public static func forWatchedFolder(path: String) -> TrackSource {
        path.localizedCaseInsensitiveContains("telegram") ? .telegram : .watched
    }

    /// A download link's source, from the host name ("www.archive.org" becomes "archive.org").
    public static func link(url: URL) -> TrackSource {
        var host = (url.host ?? "link").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return .link(host: host)
    }
}
