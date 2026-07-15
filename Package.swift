// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cleanroom",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CleanroomCore", targets: ["CleanroomCore"]),
        .library(name: "CleanroomMac", targets: ["CleanroomMac"]),
        .library(name: "CleanroomProtocol", targets: ["CleanroomProtocol"]),
        .executable(name: "cleanroom-agent", targets: ["CleanroomAgent"]),
        .executable(name: "cleanroomctl", targets: ["CleanroomCLI"]),
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
            dependencies: ["CleanroomCore", "CleanroomMac", "CleanroomProtocol"]
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
        .executableTarget(
            name: "CleanroomApp",
            dependencies: ["CleanroomCore", "CleanroomMac", "CleanroomProtocol"]
        ),
        .testTarget(
            name: "CleanroomCoreTests",
            dependencies: ["CleanroomCore"]
        ),
        .testTarget(
            name: "CleanroomMacTests",
            dependencies: ["CleanroomCore", "CleanroomMac"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
