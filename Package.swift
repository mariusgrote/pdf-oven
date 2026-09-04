// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFOven",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PDFOvenKit",
            path: "Sources/PDFOvenKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PDFOven",
            dependencies: ["PDFOvenKit"],
            path: "Sources/PDFOven",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PDFOvenCLI",
            dependencies: ["PDFOvenKit"],
            path: "Sources/PDFOvenCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
