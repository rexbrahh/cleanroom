// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cleanroom",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "CleanroomCore", targets: ["CleanroomCore"]),
        .library(name: "CleanroomMac", targets: ["CleanroomMac"]),
        .library(name: "CleanroomProtocol", targets: ["CleanroomProtocol"]),
        .executable(name: "cleanroom-agent", targets: ["CleanroomAgent"]),
        .executable(name: "cleanroomctl", targets: ["CleanroomCLI"]),
        .executable(name: "cleanroom-install-helper", targets: ["CleanroomInstallHelper"]),
        .executable(name: "cleanroom-sim", targets: ["CleanroomSimulator"]),
        .executable(name: "Cleanroom", targets: ["CleanroomApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.8.0"
        )
    ],
    targets: [
        .target(name: "CleanroomCore"),
        .target(
            name: "CleanroomMac",
            dependencies: ["CleanroomCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .target(
            name: "CleanroomProtocol",
            dependencies: ["CleanroomCore"]
        ),
        .executableTarget(
            name: "CleanroomAgent",
            dependencies: ["CleanroomCore", "CleanroomMac", "CleanroomProtocol"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CleanroomCLI",
            dependencies: [
                "CleanroomCore",
                "CleanroomMac",
                "CleanroomProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "CleanroomInstallHelper"),
        .executableTarget(name: "CleanroomSimulator", dependencies: ["CleanroomCore"]),
        .executableTarget(
            name: "CleanroomApp",
            dependencies: ["CleanroomCore", "CleanroomMac", "CleanroomProtocol"],
            linkerSettings: [
                .linkedFramework("AppIntents"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "CleanroomCoreTests",
            dependencies: ["CleanroomCore", "CleanroomProtocol"]
        ),
        .testTarget(
            name: "CleanroomMacTests",
            dependencies: ["CleanroomCore", "CleanroomMac"]
        ),
        .testTarget(
            name: "CleanroomAppTests",
            dependencies: ["CleanroomApp"]
        ),
        .testTarget(
            name: "CleanroomAgentTests",
            dependencies: ["CleanroomAgent", "CleanroomCore", "CleanroomMac", "CleanroomProtocol"]
        ),
        .testTarget(
            name: "CleanroomCLITests",
            dependencies: ["CleanroomCLI", "CleanroomCore", "CleanroomProtocol"]
        ),
        .testTarget(
            name: "CleanroomInstallHelperTests",
            dependencies: ["CleanroomInstallHelper"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
