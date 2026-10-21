// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mac2phone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mac2phone",
            path: "Sources/mac2phone",
            resources: [.copy("Resources/WebIcon.png")]
        ),
        .target(
            name: "TouchCore",
            path: "iOS/Mac2Phone",
            exclude: ["AppModel.swift", "AudioPlayer.swift", "Discovery.swift", "Mac2PhoneApp.swift",
                      "BroadcastView.swift", "WatchRelay.swift", "MirrorView.swift", "Pairing.swift", "Protocol.swift", "RootView.swift", "StreamClient.swift", "Assets.xcassets"],
            sources: ["TouchInteraction.swift"]
        ),
        .testTarget(name: "Mac2PhoneTests", dependencies: ["mac2phone", "TouchCore"])
    ]
)
