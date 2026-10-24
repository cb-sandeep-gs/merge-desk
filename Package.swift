// swift-tools-version: 6.0
// Merge Desk — branch dashboard, merge planner and history-aware conflict resolver for any git repo.
// Layout: MergeDeskCore (all logic, no UI) · MergeDeskFixtures (scripted test repos) · mergedesk (CLI).
// MergeDeskUI (view models + SwiftUI views, testable) · MergeDeskApp (the macOS app entry point only).

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
        .library(name: "MergeDeskUI", targets: ["MergeDeskUI"]),
        .executable(name: "mergedesk", targets: ["mergedesk"]),
        .executable(name: "MergeDeskApp", targets: ["MergeDeskApp"]),
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
        .target(name: "MergeDeskUI", dependencies: ["MergeDeskCore"]),
        .executableTarget(name: "MergeDeskApp", dependencies: ["MergeDeskUI"]),
        .testTarget(
            name: "MergeDeskCoreTests",
            dependencies: ["MergeDeskCore", "MergeDeskFixtures"]
        ),
        .testTarget(
            name: "MergeDeskUITests",
            dependencies: ["MergeDeskUI", "MergeDeskCore", "MergeDeskFixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
