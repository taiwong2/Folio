// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Folio",
            targets: ["Folio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.26.0"),
        // CoreML-LLM ships a Core ML-converted EmbeddingGemma 300M plus its own
        // tokenizer, exposed via `EmbeddingGemma.downloadAndLoad`/`encode`. MIT
        // licensed, SPM-distributable — this is what lets Folio deliver true
        // in-process on-device EmbeddingGemma without CocoaPods.
        .package(url: "https://github.com/john-rocky/CoreML-LLM", from: "1.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Folio",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CoreMLLLM", package: "CoreML-LLM")
            ],
            resources: [.process("Resources")]
        ),
        // Demo app. Not listed in `products` so library consumers don't pull
        // the SwiftUI sources into their build. Runnable from the package root
        // with `swift run FolioDemo`, and shows up as a scheme automatically
        // when this Package.swift is opened in Xcode.
        .executableTarget(
            name: "FolioDemo",
            dependencies: ["Folio"],
            path: "Example/Sources/FolioDemo"
        ),
        .testTarget(name: "FolioTests", dependencies: ["Folio"], resources: [.process("Fixtures")])
    ]
)

