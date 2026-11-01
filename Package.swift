// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macmond", targets: ["macmond"]),
        .executable(name: "macmonctl", targets: ["macmonctl"]),
        .executable(name: "MacMonApp", targets: ["MacMonApp"]),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MacMonCore", dependencies: ["CSMC"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "macmond", dependencies: ["MacMonCore"]),
        .executableTarget(name: "macmonctl", dependencies: ["MacMonCore"]),
        .executableTarget(name: "MacMonApp", dependencies: ["MacMonCore"]),
        .executableTarget(name: "macmon-selftest", dependencies: ["MacMonCore"]),
    ]
)
