// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Forge",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        // tree-sitter Swift wrapper (pulls in tree-sitter C core transitively)
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        // Swift grammar for tree-sitter
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.1-with-generated-files"),
        // Terminal emulator
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Forge",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Forge"
        ),
    ]
)
