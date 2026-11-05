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
        .library(name: "MeetSpaceMedia", type: .dynamic, targets: ["MeetSpaceMedia"]),
        .library(name: "MeetSpaceDesignSystem", targets: ["MeetSpaceDesignSystem"]),
        .executable(name: "FoundationPreviewRenderer", targets: ["FoundationPreviewRenderer"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "156.0.0")
    ],
    targets: [
        .target(name: "MeetSpaceCore", path: "Sources/Core"),
        .target(name: "MeetSpaceAPI", dependencies: ["MeetSpaceCore"], path: "Sources/API"),
        .target(name: "MeetSpaceStorage", dependencies: ["MeetSpaceCore"], path: "Sources/Storage"),
        .target(name: "MeetSpaceRealtime", dependencies: ["MeetSpaceCore", "MeetSpaceAPI"], path: "Sources/Realtime"),
        .target(name: "MeetSpaceMedia", dependencies: ["MeetSpaceCore", .product(name: "WebRTC", package: "WebRTC", condition: .when(platforms: [.iOS]))], path: "Sources/Media", resources: [.process("Resources")]),
        .target(name: "MeetSpaceDesignSystem", path: "Sources/DesignSystem", resources: [.process("Resources")]),
        .target(name: "MeetSpaceFeatures", dependencies: ["MeetSpaceCore", "MeetSpaceAPI", "MeetSpaceStorage", "MeetSpaceRealtime", "MeetSpaceMedia", "MeetSpaceDesignSystem"], path: "Sources/Features"),
        .executableTarget(name: "FoundationPreviewRenderer", dependencies: ["MeetSpaceFeatures", "MeetSpaceDesignSystem", "MeetSpaceCore"], path: "Tools/PreviewRenderer"),
        .testTarget(name: "CoreTests", dependencies: ["MeetSpaceCore", "MeetSpaceRealtime"]),
        .testTarget(name: "APITests", dependencies: ["MeetSpaceAPI", "MeetSpaceCore"]),
        .testTarget(name: "StorageTests", dependencies: ["MeetSpaceStorage", "MeetSpaceCore"]),
        .testTarget(name: "FeaturesTests", dependencies: ["MeetSpaceFeatures", "MeetSpaceCore", "MeetSpaceAPI"]),
        .testTarget(name: "IntegrationTests", dependencies: ["MeetSpaceCore", "MeetSpaceAPI", "MeetSpaceStorage", "MeetSpaceRealtime", "MeetSpaceMedia", "MeetSpaceFeatures"])
    ]
)
