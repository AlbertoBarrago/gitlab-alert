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
        .package(path: "GitLabKit"),
        // In-app updates. The xcframework is embedded in Contents/Frameworks by
        // bin/make-app.sh, which is why the executable needs an rpath below.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3")
    ],
    targets: [
        .executableTarget(
            name: "GitLabAlert",
            dependencies: [
                .product(name: "GitLabKit", package: "GitLabKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "GitLabAlert",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // The bundle keeps Sparkle.framework next to the executable, in
                // Contents/Frameworks. SwiftPM links it from the checkout, so
                // without this the launched app cannot find it at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "GitLabAlertTests",
            dependencies: ["GitLabAlert"],
            path: "Tests/GitLabAlertTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
