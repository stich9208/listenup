// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ListenUp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ListenUpDomain", targets: ["ListenUpDomain"]),
        .library(name: "ListenUpStorage", targets: ["ListenUpStorage"]),
        .library(name: "ListenUpAudio", targets: ["ListenUpAudio"]),
        .library(name: "ListenUpAI", targets: ["ListenUpAI"]),
        .library(name: "ListenUpExport", targets: ["ListenUpExport"]),
        .executable(name: "ListenUpApp", targets: ["ListenUpApp"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ListenUpDomain"),
        .target(name: "ListenUpStorage", dependencies: ["ListenUpDomain"]),
        .target(name: "ListenUpAudio", dependencies: ["ListenUpDomain", "ListenUpStorage"]),
        .target(
            name: "ListenUpAI",
            dependencies: ["ListenUpDomain", "ListenUpStorage"],
            exclude: ["SDKEngines.swift"]
        ),
        .target(name: "ListenUpExport", dependencies: ["ListenUpDomain", "ListenUpStorage"]),
        .executableTarget(
            name: "ListenUpApp",
            dependencies: ["ListenUpDomain", "ListenUpStorage", "ListenUpAudio", "ListenUpAI", "ListenUpExport"]
        ),
        .testTarget(name: "ListenUpDomainTests", dependencies: ["ListenUpDomain"]),
        .testTarget(name: "ListenUpStorageTests", dependencies: ["ListenUpStorage", "ListenUpDomain"]),
        .testTarget(name: "ListenUpAudioTests", dependencies: ["ListenUpAudio", "ListenUpDomain"]),
        .testTarget(name: "ListenUpAITests", dependencies: ["ListenUpAI", "ListenUpDomain"]),
        .testTarget(name: "ListenUpExportTests", dependencies: ["ListenUpExport", "ListenUpDomain"]),
    ]
)
