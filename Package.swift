// swift-tools-version:6.0
// Test harness only. The app is built from Selway.xcodeproj, which compiles
// Selway/Core/*.swift directly; this package lets `swift test` cover that
// Foundation-only logic without Xcode (see scripts/test.sh).
import PackageDescription

let package = Package(
    name: "SelwayCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SelwayCore", targets: ["SelwayCore"])],
    targets: [
        .target(name: "SelwayCore", path: "Selway/Core",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SelwayCoreTests", dependencies: ["SelwayCore"],
                    path: "Tests/SelwayCoreTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
