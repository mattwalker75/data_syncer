// swift-tools-version:5.10
// Data Syncer — an on-demand, one-way backup and sync tool for the Mac.
// `swift build` builds the core and the app; BUILD_APP.sh wraps the app into "Data Syncer.app".
import PackageDescription

let package = Package(
    name: "DataSyncer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DataSyncerCore", targets: ["DataSyncerCore"]),
        .executable(name: "DataSyncer", targets: ["DataSyncer"]),
    ],
    targets: [
        // Everything that copies, compares, records and restores. No UI, no AppKit — testable on its own.
        .target(name: "DataSyncerCore", path: "Sources/DataSyncerCore"),
        // The SwiftUI app (the windows). Thin: it drives the core and shows what it reports.
        .executableTarget(name: "DataSyncer", dependencies: ["DataSyncerCore"], path: "Sources/DataSyncer"),
        .testTarget(name: "DataSyncerCoreTests", dependencies: ["DataSyncerCore"], path: "Tests/DataSyncerCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
