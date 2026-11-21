// swift-tools-version: 6.2
//
// Root package for the portable, testable logic of Applebot.
//
// The package lives at the repo root so that the single `tests/` folder can be
// used as the test location (SwiftPM does not allow target paths that escape
// the package root). The iOS app (ios/App) consumes these libraries as a local
// package dependency.
//
// LLMKit, RAGKit and ConnectorKit are pure Swift on Linux, so `swift test` runs inside Docker
// (see docker-compose.yml). Apple-only code (FoundationModels, NaturalLanguage,
// PDFKit, Vision, SQLite3, EventKit, Security) is fenced with `#if canImport(...)`.

import PackageDescription

let package = Package(
    name: "Applebot",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "LLMKit", targets: ["LLMKit"]),
        .library(name: "RAGKit", targets: ["RAGKit"]),
        .library(name: "ConnectorKit", targets: ["ConnectorKit"]),
    ],
    targets: [
        .target(
            name: "LLMKit",
            path: "ios/Kit/LLMKit"
        ),
        .target(
            name: "RAGKit",
            dependencies: ["LLMKit"],
            path: "ios/Kit/RAGKit"
        ),
        .target(
            name: "ConnectorKit",
            dependencies: ["LLMKit"],
            path: "ios/Kit/ConnectorKit"
        ),
        .testTarget(
            name: "LLMKitTests",
            dependencies: ["LLMKit"],
            path: "tests/LLMKitTests"
        ),
        .testTarget(
            name: "RAGKitTests",
            dependencies: ["RAGKit", "LLMKit"],
            path: "tests/RAGKitTests"
        ),
        .testTarget(
            name: "ConnectorKitTests",
            dependencies: ["ConnectorKit", "LLMKit"],
            path: "tests/ConnectorKitTests"
        ),
    ]
)
