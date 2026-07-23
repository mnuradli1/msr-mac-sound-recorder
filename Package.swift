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
        .library(name: "MSRServices", targets: ["MSRServices"]),
        .library(name: "MSRPresentation", targets: ["MSRPresentation"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.12.0")
    ],
    targets: [
        .target(
            name: "MSRCore",
            dependencies: ["ZIPFoundation"]
        ),
        .target(
            name: "MSRServices",
            dependencies: ["MSRCore"]
        ),
        .target(
            name: "MSRPresentation",
            dependencies: ["MSRCore"]
        ),
        .executableTarget(
            name: "MSRMeetingRecorder",
            dependencies: ["MSRCore", "MSRServices", "MSRPresentation"],
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
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
