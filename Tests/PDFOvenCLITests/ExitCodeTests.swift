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

  // MARK: - Helpers

  private func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
  }

  private func pdfoven(_ arguments: String...) throws -> (status: Int32, errors: String) {
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
    process.standardOutput = Pipe()
    process.standardError = errors
    try process.run()
    let written = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: written, as: UTF8.self))
  }
}
