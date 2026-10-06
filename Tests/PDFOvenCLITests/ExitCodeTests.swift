import Foundation
import PDFOvenFixtures
import XCTest

/// Runs the built `pdfoven` the way a shell does, because the promise being kept is about
/// the process: a bad call is status 2 with nothing written, a PDF that will not open is
/// status 1 after the run went ahead.
final class ExitCodeTests: XCTestCase {
  private var directory = URL(fileURLWithPath: "/")

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-cli-exit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testValidPDFExtractsAndExitsZero() throws {
    try FixturePDF.data().write(to: directory.appendingPathComponent("fixture.pdf"))
    let run = try pdfoven("extract", "fixture.pdf")

    XCTAssertEqual(run.status, 0, run.errors)
    XCTAssertTrue(exists("fixture-images"))
  }

  /// The bad argument comes last, so the extraction of the good one would already have run
  /// had the paths not been checked up front.
  func testBadArgumentExitsTwoAndLeavesNothingBehind() throws {
    try FixturePDF.data().write(to: directory.appendingPathComponent("fixture.pdf"))
    let run = try pdfoven("extract", "fixture.pdf", "missing.pdf")

    XCTAssertEqual(run.status, 2, run.errors)
    XCTAssertEqual(run.errors, "pdfoven: file or directory not found: missing.pdf\n")
    XCTAssertFalse(exists("fixture-images"))
  }

  func testUnreadablePDFExitsOne() throws {
    try Data("%PDF-1.4 and then nothing that parses".utf8)
      .write(to: directory.appendingPathComponent("broken.pdf"))
    let run = try pdfoven("extract", "broken.pdf")

    XCTAssertEqual(run.status, 1, run.errors)
    // CoreGraphics writes a complaint of its own to stderr first, so match the line rather
    // than the whole stream.
    XCTAssertTrue(
      run.errors.contains("pdfoven: broken.pdf is not a readable PDF."), run.errors)
  }

  func testReplaceKeepsSameBasenameExtractionsSeparate() throws {
    for name in ["a", "b"] {
      let folder = directory.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FixturePDF.data().write(to: folder.appendingPathComponent("plan.pdf"))
    }
    let run = try pdfoven("extract", "--replace", "--out", "output", "a/plan.pdf", "b/plan.pdf")
    XCTAssertEqual(run.status, 0, run.errors)
    for name in ["plan-images", "plan-images 2"] {
      let folder = directory.appendingPathComponent("output/\(name)")
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: folder.path).count,
        FixturePDF.Expectation.writtenFiles)
    }
  }

  func testUnreadableImageReportsPartialExtractionAndExitsOne() throws {
    var data = FixturePDF.data()
    let range = try XCTUnwrap(data.range(of: Data("/Width 4 /Height 4".utf8)))
    data.replaceSubrange(range, with: Data("/Width 0 /Height 4".utf8))
    try data.write(to: directory.appendingPathComponent("fixture.pdf"))
    let run = try pdfoven("extract", "fixture.pdf")
    XCTAssertEqual(run.status, 1)
    XCTAssertTrue(run.errors.contains("1 image occurrence could not be extracted."), run.errors)
    XCTAssertTrue(run.output.contains("2 duplicates"), run.output)
    XCTAssertTrue(run.output.contains("1 unreadable"), run.output)
    XCTAssertTrue(exists("fixture-images/p001-01.jpg"))
  }

  // MARK: - Helpers

  private func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
  }

  private func pdfoven(_ arguments: String...) throws -> (
    status: Int32, errors: String, output: String
  ) {
    let binary = Bundle(for: type(of: self)).bundleURL
      .deletingLastPathComponent()
      .appendingPathComponent("PDFOvenCLI")
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: binary.path),
      "no pdfoven binary next to the test bundle at \(binary.path)")

    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let errors = Pipe()
    let output = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let written = errors.fileHandleForReading.readDataToEndOfFile()
    let summary = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus, String(decoding: written, as: UTF8.self),
      String(decoding: summary, as: UTF8.self)
    )
  }
}
