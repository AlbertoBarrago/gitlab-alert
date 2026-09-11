// swift-tools-version: 6.0
import PackageDescription

// Pure SwiftPM: no .xcodeproj, no Xcode. `bin/make-app.sh` assembles the
// .app bundle around this executable and signs it.
let package = Package(
    name: "GitLabAlert",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GitLabAlert", targets: ["GitLabAlert"])
    ],
    dependencies: [
        .package(path: "GitLabKit")
    ],
    targets: [
        .executableTarget(
            name: "GitLabAlert",
            dependencies: [.product(name: "GitLabKit", package: "GitLabKit")],
            path: "GitLabAlert",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GitLabAlertTests",
            dependencies: ["GitLabAlert"],
            path: "Tests/GitLabAlertTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
