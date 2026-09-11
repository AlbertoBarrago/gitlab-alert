// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitLabKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitLabKit", targets: ["GitLabKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GitLabKit",
            dependencies: [],
            path: "Sources/GitLabKit"
        ),
        .testTarget(
            name: "GitLabKitTests",
            dependencies: ["GitLabKit"],
            path: "Tests/GitLabKitTests"
        )
    ]
)
