// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Stats",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Stats",
            path: "Sources/Stats",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
