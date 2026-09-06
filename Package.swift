// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaVadis",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
        .executable(name: "quotactl", targets: ["quotactl"]),
    ],
    targets: [
        .target(
            name: "QuotaCore",
            linkerSettings: [.linkedLibrary("sqlite3", .when(platforms: [.macOS])), .linkedFramework("CloudKit")]),
        .executableTarget(name: "quotactl", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"], resources: [.copy("Fixtures")]),
    ])
