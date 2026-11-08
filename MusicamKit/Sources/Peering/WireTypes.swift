import Foundation
import Domain
import Sync

struct Hello: Codable, Sendable {
    var deviceID: DeviceID
    var deviceName: String
    var protocolVersion: Int
    var vector: VersionVector
}

struct ChangesBatch: Codable, Sendable {
    var entries: [ChangeEntry]
}

struct FileRequest: Codable, Sendable {
    var fileID: LibraryFileID
    /// Bytes the requester already holds from an earlier, interrupted transfer.
    var offset: Int64
}

struct FileHeader: Codable, Sendable {
    var fileID: LibraryFileID
    var size: Int64
    var offset: Int64
    var hash: String
}

struct ArtworkRequest: Codable, Sendable {
    var keys: [String]
}

struct FileEnd: Codable, Sendable {
    var fileID: LibraryFileID
}

struct FileFailure: Codable, Sendable {
    var fileID: LibraryFileID
    var reason: String
}

/// What the UI hears about.
public enum SyncEvent: Sendable, Equatable {
    case peerConnected(name: String)
    case peerDisconnected(name: String)
    case recordsReceived(count: Int)
    case upToDate
    case fileProgress(LibraryFileID, received: Int64, total: Int64)
    case fileReceived(LibraryFileID)
    case artworkReceived
    case problem(String)
}

public struct PeerInfo: Sendable, Equatable, Identifiable {
    public var id: DeviceID
    public var name: String
}
