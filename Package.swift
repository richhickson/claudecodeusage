// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: [],
            path: "ClaudeUsage"
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: [],
            path: "ClaudeUsageTests"
        )
    ]
)
