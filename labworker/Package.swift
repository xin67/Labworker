// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CloneStudio",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(
            name: "CloneStudioCore",
            targets: ["CloneStudioCore"]
        ),
        .executable(
            name: "CloneStudio",
            targets: ["CloneStudio"]
        ),
        .executable(
            name: "CloneStudioVerify",
            targets: ["CloneStudioVerify"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CloneStudioCore",
            dependencies: [],
            path: "Sources/CloneStudioCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "CloneStudio",
            dependencies: ["CloneStudioCore"],
            path: "Sources/CloneStudio"
        ),
        .executableTarget(
            name: "CloneStudioVerify",
            dependencies: ["CloneStudioCore"],
            path: "Tests/CloneStudioVerify"
        )
    ],
    swiftLanguageModes: [.v5]
)
