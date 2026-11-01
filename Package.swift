// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macpitd", targets: ["macpitd"]),
        .executable(name: "macpitctl", targets: ["macpitctl"]),
        .executable(name: "MacPitApp", targets: ["MacPitApp"]),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MacPitCore", dependencies: ["CSMC"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "macpitd", dependencies: ["MacPitCore"]),
        .executableTarget(name: "macpitctl", dependencies: ["MacPitCore"]),
        .executableTarget(name: "MacPitApp", dependencies: ["MacPitCore"]),
        .executableTarget(name: "macpit-selftest", dependencies: ["MacPitCore"]),
    ]
)
