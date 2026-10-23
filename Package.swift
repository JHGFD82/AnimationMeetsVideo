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
            path: "Sources/AnimationMeetsVideo",
            // The effect packages that ship with the app, copied as they
            // are: their Metal is compiled by Core Image at run time.
            resources: [.copy("Resources/Effects")]
        ),
        .testTarget(
            name: "AnimationMeetsVideoTests",
            dependencies: ["AnimationMeetsVideo"],
            // Read by LookReferenceTests from beside its source.
            exclude: ["Rendering/LookReferences"]
        )
    ]
)
