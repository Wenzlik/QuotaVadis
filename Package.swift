// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaVadis",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
        .library(name: "QuotaUI", targets: ["QuotaUI"]),
        .executable(name: "quotavadis", targets: ["quotavadis"]),
    ],
    targets: [
        .target(
            name: "QuotaCore",
            linkerSettings: [.linkedLibrary("sqlite3", .when(platforms: [.macOS])), .linkedFramework("CloudKit")]),
        .target(name: "QuotaUI", dependencies: ["QuotaCore"]),
        .executableTarget(name: "quotavadis", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"], resources: [.copy("Fixtures")]),
    ])
