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
    // The test fixture is a PDF assembled byte by byte; the tests assert against it and
    // MakeTestPDF writes it out for looking at by hand.
    .target(
      name: "PDFOvenFixtures",
      path: "Sources/PDFOvenFixtures",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "MakeTestPDF",
      dependencies: ["PDFOvenFixtures"],
      path: "Tools",
      exclude: ["make-icon.swift"],
      sources: ["make-test-pdf.swift"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PDFOvenAppTests",
      dependencies: ["PDFOven", "PDFOvenFixtures"],
      path: "Tests/PDFOvenAppTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PDFOvenKitTests",
      dependencies: ["PDFOvenKit", "PDFOvenFixtures"],
      path: "Tests/PDFOvenKitTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
