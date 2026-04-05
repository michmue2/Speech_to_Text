// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SpeechText",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpeechText", targets: ["SpeechTextApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/whisperkit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpeechTextApp",
            dependencies: [
                .product(name: "WhisperKit", package: "whisperkit"),
            ],
            path: "Sources/speechTextApp"
        ),
    ]
)
