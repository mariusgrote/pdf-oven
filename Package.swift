// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFOven",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PDFOven",
            path: "Sources/PDFOven",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
