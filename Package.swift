// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "opdiff",
    platforms: [.macOS(.v14)],
    targets: [
        // Git + diff parsing, no UI. Kept separate so it can be unit tested.
        .target(name: "DiffCore", path: "Sources/DiffCore"),
        // The SwiftUI app.
        .executableTarget(name: "opdiff", dependencies: ["DiffCore"], path: "Sources/opdiff"),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"], path: "Tests/DiffCoreTests"),
    ]
)
