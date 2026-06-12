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
        .library(name: "VoCalCapture", targets: ["VoCalCapture"]),
        .library(name: "VoCalVoice", targets: ["VoCalVoice"]),
    ],
    targets: [
        .target(name: "VoCalCore"),
        .target(name: "VoCalCapture"),
        // Mirrors Serein's wiring (SereinVoice depends on SereinCapture); VoCalCore stays
        // for shared codecs/IDs per the Phase C plan.
        .target(name: "VoCalVoice", dependencies: ["VoCalCapture", "VoCalCore"]),
        .testTarget(name: "VoCalCoreTests", dependencies: ["VoCalCore"]),
        .testTarget(name: "VoCalCaptureTests", dependencies: ["VoCalCapture"]),
        .testTarget(
            name: "VoCalVoiceTests",
            dependencies: ["VoCalVoice", "VoCalCapture", "VoCalCore"]
        ),
    ]
)
