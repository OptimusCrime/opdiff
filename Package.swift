// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "opdiff",
    platforms: [.macOS(.v14)],
    products: [
        // The binary keeps the command-line name; the .app bundle wraps it (scripts/build-app.sh).
        .executable(name: "opdiff", targets: ["OptimusDiff"])
    ],
    dependencies: [
        // Syntax highlighting: highlight.js in JavaScriptCore, ~190 languages, 250 themes.
        .package(url: "https://github.com/smittytone/HighlighterSwift", from: "3.1.0")
    ],
    targets: [
        // Git + diff parsing, no UI. Kept separate so it can be unit tested.
        .target(name: "DiffCore", path: "Sources/DiffCore"),
        // The SwiftUI app.
        .executableTarget(
            name: "OptimusDiff",
            dependencies: ["DiffCore", .product(name: "Highlighter", package: "HighlighterSwift")],
            path: "Sources/OptimusDiff"),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"], path: "Tests/DiffCoreTests"),
    ]
)
