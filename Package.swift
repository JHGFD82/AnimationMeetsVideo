// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AnimationMeetsVideo",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "AnimationMeetsVideo",
            targets: ["AnimationMeetsVideo"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AnimationMeetsVideo",
            path: "Sources/AnimationMeetsVideo"
        ),
        .testTarget(
            name: "AnimationMeetsVideoTests",
            dependencies: ["AnimationMeetsVideo"]
        )
    ]
)
