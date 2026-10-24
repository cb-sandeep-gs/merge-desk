// swift-tools-version: 6.0
// Merge Desk — branch dashboard, merge planner and history-aware conflict resolver for any git repo.
// Layout: MergeDeskCore (all logic, no UI) · MergeDeskFixtures (scripted test repos) · mergedesk (CLI).
// The SwiftUI app target arrives in MD-1 and stays a thin layer over MergeDeskCore.

import PackageDescription

let package = Package(
    name: "MergeDesk",
    platforms: [
        // macOS 14: SwiftUI Table, MenuBarExtra and SMAppService (used from MD-1/MD-2).
        .macOS(.v14),
    ],
    products: [
        .library(name: "MergeDeskCore", targets: ["MergeDeskCore"]),
        .library(name: "MergeDeskFixtures", targets: ["MergeDeskFixtures"]),
        .executable(name: "mergedesk", targets: ["mergedesk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "MergeDeskCore"),
        .target(name: "MergeDeskFixtures", dependencies: ["MergeDeskCore"]),
        .executableTarget(
            name: "mergedesk",
            dependencies: [
                "MergeDeskCore",
                "MergeDeskFixtures",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MergeDeskCoreTests",
            dependencies: ["MergeDeskCore", "MergeDeskFixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
