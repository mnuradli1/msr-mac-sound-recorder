// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MSRMacSoundRecorder",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MSRMeetingRecorder", targets: ["MSRMeetingRecorder"]),
        .library(name: "MSRCore", targets: ["MSRCore"]),
        .library(name: "MSRServices", targets: ["MSRServices"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.12.0")
    ],
    targets: [
        .target(
            name: "MSRCore"
        ),
        .target(
            name: "MSRServices",
            dependencies: ["MSRCore"]
        ),
        .executableTarget(
            name: "MSRMeetingRecorder",
            dependencies: ["MSRCore", "MSRServices"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MSRTestRunner",
            dependencies: ["MSRCore", "MSRServices"]
        ),
        .testTarget(
            name: "MSRCoreTests",
            dependencies: [
                "MSRCore",
                "MSRServices",
                "MSRMeetingRecorder",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
