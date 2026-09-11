// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TeamChannelMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TeamChannelMonitor",
            path: "Sources/TeamChannelMonitor",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
