// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // All tiling logic lives in a library so it can be exercised by the checks executable.
        .target(
            name: "TesseraCore",
            path: "Sources/TesseraCore"
        ),
        // The thin SwiftUI menu-bar app.
        .executableTarget(
            name: "Tessera",
            dependencies: ["TesseraCore"],
            path: "Sources/Tessera"
        ),
        // Standalone assertion harness. `swift test` can't run on a Command Line Tools-only install
        // (no XCTest/Testing runtime), so checks are a plain executable: `swift run TesseraChecks`.
        .executableTarget(
            name: "TesseraChecks",
            dependencies: ["TesseraCore"],
            path: "Tests/Checks"
        )
    ]
)
