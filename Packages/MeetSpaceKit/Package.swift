// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetSpaceKit",
    defaultLocalization: "ru",
    platforms: [.iOS(.v18), .macOS(.v15)], // macOS is a host for local verification, not a shipped app.
    products: [
        .library(name: "MeetSpaceFeatures", targets: ["MeetSpaceFeatures"]),
        .library(name: "MeetSpaceCore", targets: ["MeetSpaceCore"]),
        .library(name: "MeetSpaceAPI", targets: ["MeetSpaceAPI"]),
        .library(name: "MeetSpaceStorage", targets: ["MeetSpaceStorage"]),
        .library(name: "MeetSpaceRealtime", targets: ["MeetSpaceRealtime"]),
        .library(name: "MeetSpaceMedia", targets: ["MeetSpaceMedia"]),
        .library(name: "MeetSpaceCalling", targets: ["MeetSpaceCalling"]),
        .library(name: "MeetSpaceBroadcast", targets: ["MeetSpaceBroadcast"]),
        .library(name: "MeetSpaceDesignSystem", targets: ["MeetSpaceDesignSystem"]),
        .executable(name: "FoundationPreviewRenderer", targets: ["FoundationPreviewRenderer"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "156.0.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", revision: "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.4"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.90.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(name: "MeetSpaceCore", path: "Sources/Core"),
        .target(name: "MeetSpaceAPI", dependencies: ["MeetSpaceCore"], path: "Sources/API"),
        .target(name: "MeetSpaceStorage", dependencies: ["MeetSpaceCore"], path: "Sources/Storage"),
        .target(name: "MeetSpaceRealtime", dependencies: ["MeetSpaceCore", "MeetSpaceAPI"], path: "Sources/Realtime"),
        .target(name: "MeetSpaceBroadcast", path: "Sources/Broadcast"),
        .target(name: "MeetSpaceMedia", dependencies: ["MeetSpaceCore", "MeetSpaceBroadcast", .product(name: "WebRTC", package: "WebRTC", condition: .when(platforms: [.iOS]))], path: "Sources/Media", resources: [.process("Resources")]),
        .target(name: "MeetSpaceCalling", dependencies: ["MeetSpaceMedia"], path: "Sources/Calling"),
        .target(name: "MeetSpaceDesignSystem", path: "Sources/DesignSystem", resources: [.process("Resources")]),
        .target(name: "MeetSpaceInstaller", dependencies: [.product(name: "Citadel", package: "Citadel"), .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto")], path: "Sources/Installer", resources: [.copy("Resources")]),
        .target(name: "MeetSpaceFeatures", dependencies: ["MeetSpaceInstaller", "MeetSpaceCore", "MeetSpaceAPI", "MeetSpaceStorage", "MeetSpaceRealtime", "MeetSpaceMedia", "MeetSpaceCalling", "MeetSpaceBroadcast", "MeetSpaceDesignSystem"], path: "Sources/Features"),
        .executableTarget(name: "FoundationPreviewRenderer", dependencies: ["MeetSpaceFeatures", "MeetSpaceDesignSystem", "MeetSpaceCore"], path: "Tools/PreviewRenderer"),
        .testTarget(name: "InstallerTests", dependencies: ["MeetSpaceInstaller"]),
        .testTarget(name: "CoreTests", dependencies: ["MeetSpaceCore", "MeetSpaceRealtime"]),
        .testTarget(name: "APITests", dependencies: ["MeetSpaceAPI", "MeetSpaceCore"]),
        .testTarget(name: "StorageTests", dependencies: ["MeetSpaceStorage", "MeetSpaceCore"]),
        .testTarget(name: "FeaturesTests", dependencies: ["MeetSpaceFeatures", "MeetSpaceCore", "MeetSpaceAPI"]),
        .testTarget(name: "BroadcastTests", dependencies: ["MeetSpaceBroadcast"]),
        .testTarget(name: "IntegrationTests", dependencies: ["MeetSpaceCore", "MeetSpaceAPI", "MeetSpaceStorage", "MeetSpaceRealtime", "MeetSpaceMedia", "MeetSpaceCalling", "MeetSpaceBroadcast", "MeetSpaceFeatures"])
    ]
)
