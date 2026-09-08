import Foundation
import PDFOvenFixtures
import PDFOvenKit
import XCTest

@testable import PDFOvenCLI

/// A path that names no readable PDF is a mistake in the call, and the CLI has to say so
/// while it can still say it about the argument the caller typed. These tests pin the
/// distinctions `Destination.expand` throws away — missing, wrong kind, empty folder — and
/// the rule that one bad argument stops the whole run rather than the arguments after it.
final class ArgumentTests: XCTestCase {
  private var directory = URL(fileURLWithPath: "/")

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testMissingPDFIsRejected() throws {
    let message = try failure(for: ["extract", "missing.pdf"])
    XCTAssertEqual(message, "file or directory not found: missing.pdf")
  }

  func testExistingFileWithoutPDFExtensionIsRejected() throws {
    try Data("not a PDF".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    let message = try failure(for: ["extract", "notes.txt"])
    XCTAssertEqual(message, "not a PDF file: notes.txt")
  }

  func testMissingDirectoryIsRejected() throws {
    let message = try failure(for: ["extract", "elsewhere"])
    XCTAssertEqual(message, "file or directory not found: elsewhere")
  }

  func testEmptyDirectoryIsRejectedByName() throws {
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("empty", isDirectory: true),
      withIntermediateDirectories: true)
    let message = try failure(for: ["extract", "empty"])
    XCTAssertEqual(message, "no PDFs in directory: empty")
  }

  func testDirectoryStillCollectsPDFsBelowIt() throws {
    let nested = directory.appendingPathComponent("tree/deeper", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FixturePDF.data().write(to: nested.appendingPathComponent("fixture.pdf"))

    let command = try extraction(for: ["extract", "tree"])
    XCTAssertEqual(command.inputs.map(\.lastPathComponent), ["fixture.pdf"])
  }

  /// The whole call fails, so the valid PDF in front of the bad argument is never extracted.
  func testValidPDFIsDroppedWhenAnotherArgumentIsBad() throws {
    try FixturePDF.data().write(to: directory.appendingPathComponent("fixture.pdf"))
    let message = try failure(for: ["extract", "fixture.pdf", "missing.pdf"])
    XCTAssertEqual(message, "file or directory not found: missing.pdf")
  }

  /// A PDF CoreGraphics cannot open passes the argument check — it exists and is a PDF —
  /// and stays a runtime failure of the extraction rather than a call error.
  func testUnreadablePDFIsAcceptedAndFailsWhileExtracting() throws {
    let input = directory.appendingPathComponent("broken.pdf")
    try Data("%PDF-1.4 and then nothing that parses".utf8).write(to: input)

    let command = try extraction(for: ["extract", "broken.pdf"])
    XCTAssertEqual(command.inputs.map(\.lastPathComponent), ["broken.pdf"])
    XCTAssertThrowsError(try ImageExtractor().extract(input, options: command.placement)) {
      guard case ExtractError.cannotOpen = $0 else {
        return XCTFail("opening a corrupt PDF ended as \($0)")
      }
    }
  }

  func testDeviceFileNamesItsType() throws {
    let message = try failure(for: ["extract", "/dev/null"])
    XCTAssertEqual(message, "unsupported file type: /dev/null is a device")
  }

  func testRelativePathsResolveAgainstTheWorkingDirectory() throws {
    let nested = directory.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FixturePDF.data().write(to: nested.appendingPathComponent("fixture.pdf"))

    let command = try extraction(for: ["extract", "--out", "out", "sub/fixture.pdf"])
    XCTAssertEqual(command.inputs, [nested.appendingPathComponent("fixture.pdf")])
    XCTAssertEqual(command.placement.folder, directory.appendingPathComponent("out"))
  }

  func testHelpAndUnknownOptionsKeepTheirStatus() throws {
    guard case .usage(let status) = parseCommandLine(["--help"], relativeTo: directory) else {
      return XCTFail("--help did not ask for the usage")
    }
    XCTAssertEqual(status, 0)
    guard case .usage(let empty) = parseCommandLine([], relativeTo: directory) else {
      return XCTFail("an empty command line did not ask for the usage")
    }
    XCTAssertEqual(empty, 2)
    XCTAssertEqual(try failure(for: ["extract", "--nope"]), "unknown option '--nope'")
  }

  // MARK: - Helpers

  private func extraction(
    for arguments: [String], file: StaticString = #filePath, line: UInt = #line
  ) throws -> ExtractCommand {
    switch parseCommandLine(arguments, relativeTo: directory) {
    case .extract(let command): return command
    case .usage: throw fail("\(arguments) asked for the usage", file: file, line: line)
    case .failure(let message): throw fail(message, file: file, line: line)
    }
  }

  private func failure(
    for arguments: [String], file: StaticString = #filePath, line: UInt = #line
  ) throws -> String {
    switch parseCommandLine(arguments, relativeTo: directory) {
    case .extract(let command):
      throw fail("\(arguments) was accepted as \(command.inputs)", file: file, line: line)
    case .usage: throw fail("\(arguments) asked for the usage", file: file, line: line)
    case .failure(let message): return message
    }
  }

  private func fail(_ message: String, file: StaticString, line: UInt) -> Error {
    XCTFail(message, file: file, line: line)
    return CocoaError(.fileNoSuchFile)
  }
}
