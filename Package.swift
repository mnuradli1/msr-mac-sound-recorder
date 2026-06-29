// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MSRMacSoundRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MSRMeetingRecorder", targets: ["MSRMeetingRecorder"]),
        .library(name: "MSRCore", targets: ["MSRCore"]),
        .library(name: "MSRServices", targets: ["MSRServices"])
    ],
    targets: [
        .target(name: "MSRCore"),
        .target(
            name: "MSRServices",
            dependencies: ["MSRCore"]
        ),
        .executableTarget(
            name: "MSRMeetingRecorder",
            dependencies: ["MSRCore", "MSRServices"]
        ),
        .executableTarget(
            name: "MSRTestRunner",
            dependencies: ["MSRCore", "MSRServices"]
        )
    ]
)
