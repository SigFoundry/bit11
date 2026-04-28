// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bit11",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "bit11",
            path: "Sources/bit11",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
