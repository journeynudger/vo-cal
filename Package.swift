// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoCalKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "VoCalCore", targets: ["VoCalCore"]),
        .library(name: "VoCalVoice", targets: ["VoCalVoice"]),
    ],
    targets: [
        .target(name: "VoCalCore"),
        .target(name: "VoCalVoice", dependencies: ["VoCalCore"]),
        .testTarget(name: "VoCalCoreTests", dependencies: ["VoCalCore"]),
        .testTarget(name: "VoCalVoiceTests", dependencies: ["VoCalVoice"]),
    ]
)
