// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LemmaryLocalAI",
    platforms: [
        // RecognizeDocumentsRequest, the whole OCR engine, is macOS 26 and later.
        .macOS(.v26),
    ],
    products: [
        .executable(name: "LemmaryLocalAI", targets: ["LemmaryLocalAI"]),
        .executable(name: "ocr-worker", targets: ["OCRWorker"]),
        .library(name: "LocalAIKit", targets: ["LocalAIKit"]),
    ],
    dependencies: [
        // The app's updater; Scripts/appcast.sh writes its feed.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.10.0")),
    ],
    targets: [
        // Everything decided without a window, Vision or a model: HTTP, multipart,
        // the docling-compatible API, layout-to-markdown, the worker protocol and
        // the llama-server command line. The half with tests.
        .target(
            name: "LocalAIKit",
            path: "Sources/LocalAIKit"
        ),
        // Vision and PDF rendering. Only the worker links it, so a hang inside
        // Vision can only ever take down a process the app is allowed to kill.
        .target(
            name: "VisionOCR",
            dependencies: ["LocalAIKit"],
            path: "Sources/VisionOCR"
        ),
        .executableTarget(
            name: "OCRWorker",
            dependencies: ["LocalAIKit", "VisionOCR"],
            path: "Sources/OCRWorker"
        ),
        .executableTarget(
            name: "LemmaryLocalAI",
            dependencies: [
                "LocalAIKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/LemmaryLocalAI",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "LocalAIKitTests",
            dependencies: ["LocalAIKit"],
            path: "Tests/LocalAIKitTests"
        ),
        .testTarget(
            name: "VisionOCRTests",
            dependencies: ["VisionOCR", "LocalAIKit"],
            path: "Tests/VisionOCRTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
