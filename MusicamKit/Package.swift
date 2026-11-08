// swift-tools-version:6.0
import PackageDescription

// Modules are added phase by phase (see the architecture document, section 10).
// Dependency rule: Features -> services -> Domain. Domain imports nothing but Foundation.
let package = Package(
    name: "MusicamKit",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Importing", targets: ["Importing"]),
        .library(name: "Playback", targets: ["Playback"]),
        .library(name: "Sync", targets: ["Sync"]),
        .library(name: "Peering", targets: ["Peering"]),
        .library(name: "Metadata", targets: ["Metadata"]),
        .library(name: "MerajCore", targets: ["MerajCore"]),
        .library(name: "Acquisition", targets: ["Acquisition"]),
        .library(name: "Features", targets: ["Features"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Persistence", dependencies: ["Domain", "Sync"]),
        .target(name: "Importing", dependencies: ["Domain", "Persistence"]),
        .target(name: "Playback", dependencies: ["Domain"]),
        .target(name: "Sync", dependencies: ["Domain"]),
        .target(name: "Metadata", dependencies: ["Domain"]),
        // Spotify page parsing, YouTube result matching and file naming, copied from the Merajfy project (pure Foundation).
        .target(name: "MerajCore"),
        .target(name: "Acquisition", dependencies: ["Domain", "Importing", "Metadata", "MerajCore"]),
        .target(name: "Peering", dependencies: ["Domain", "Sync", "Persistence", "Importing"]),
        .target(name: "Features", dependencies: ["Domain", "Persistence", "Importing", "Playback", "Sync", "Peering", "Metadata", "Acquisition"]),
        .testTarget(name: "PlaybackTests", dependencies: ["Playback", "Domain"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "Domain"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Domain", "Sync"]),
        .testTarget(name: "ImportingTests", dependencies: ["Importing", "Persistence", "Domain"]),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata", "Domain"]),
        .testTarget(name: "PeeringTests", dependencies: ["Peering", "Importing", "Persistence", "Domain", "Sync"]),
        .testTarget(name: "MerajCoreTests", dependencies: ["MerajCore"]),
        .testTarget(name: "AcquisitionTests", dependencies: ["Acquisition", "Importing", "Persistence", "Metadata", "Domain", "MerajCore"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "Importing", "Persistence", "Playback", "Domain", "Peering", "Metadata", "Acquisition"]),
    ]
)
