import CoreGraphics
import Foundation
import ImageIO
import PDFOvenFixtures
import XCTest

@testable import PDFOvenKit

final class ImageExtractorTests: XCTestCase {
  func testDefaultExtraction() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let result = try ImageExtractor().extract(fixture.input, options: Options())

    XCTAssertEqual(result.written, FixturePDF.Expectation.writtenFiles)
    XCTAssertEqual(result.skipped, 1)

    let files = try FileManager.default.contentsOfDirectory(
      at: result.folder, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, FixturePDF.Expectation.writtenFiles)
    XCTAssertEqual(
      try Data(contentsOf: result.folder.appendingPathComponent("p001-01.jpg")),
      FixturePDF.embeddedJPEG())

    XCTAssertTrue(files.contains { $0.lastPathComponent.contains("-stamp.") })
    let attachmentURL = try XCTUnwrap(
      files.first { $0.lastPathComponent.contains("-attach-") })
    let attachmentSource = try XCTUnwrap(CGImageSourceCreateWithURL(attachmentURL as CFURL, nil))
    let attachment = try XCTUnwrap(CGImageSourceCreateImageAtIndex(attachmentSource, 0, nil))
    XCTAssertEqual(attachment.width, 96)
    XCTAssertEqual(attachment.height, 96)
  }

  func testSoftMaskBecomesAlpha() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let result = try ImageExtractor().extract(fixture.input, options: Options())
    let alpha = try alphaChannel(of: result.folder.appendingPathComponent("p001-02.png"))

    XCTAssertEqual(alpha.filter { $0 == 255 }.count, FixturePDF.Expectation.opaquePixels)
  }

  /// The other shape of `/Mask`: an array of ranges rather than a stream. The fixture's image
  /// was built so exactly its left half falls inside them.
  func testColorKeyMaskBecomesTransparent() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let result = try ImageExtractor().extract(fixture.input, options: Options())
    let alpha = try alphaChannel(of: result.folder.appendingPathComponent("p004-02.png"))

    XCTAssertEqual(
      alpha.filter { $0 == 0 }.count, FixturePDF.Expectation.colorKeyTransparentPixels)
    XCTAssertEqual(
      alpha.filter { $0 == 255 }.count, FixturePDF.Expectation.colorKeyTransparentPixels)
  }

  func testOptionsCanKeepRepeatsAndExcludeMarkup() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let options = ExtractOptions(includeMarkup: false, dedupe: false)
    let result = try ImageExtractor(extractOptions: options).extract(
      fixture.input, options: Options())

    // Every page image, the repeated logo among them; the stamp and the attachment are not.
    XCTAssertEqual(result.written, 9)
    let files = try FileManager.default.contentsOfDirectory(
      at: result.folder, includingPropertiesForKeys: nil)
    XCTAssertFalse(files.contains { $0.lastPathComponent.contains("-stamp.") })
    XCTAssertFalse(files.contains { $0.lastPathComponent.contains("-attach-") })
  }

  func testImagesFolderNeverContainsAnInput() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let protected = fixture.directory.appendingPathComponent("fixture-images/input.pdf")
    let destination = Destination.imagesFolder(
      for: fixture.input, folder: nil, replace: true, protecting: [protected])
    XCTAssertEqual(destination.lastPathComponent, "fixture-images 2")
  }

  func testEmbeddedFilenameCannotEscapeOutputFolder() {
    XCTAssertEqual(FileType.sanitize("../../.secret.png"), "secret")
    XCTAssertEqual(FileType.sanitize("..\\..\\invoice:final.jpg"), "invoice-final")
  }

  func testUnwritableFolderFailsTheExtraction() throws {
    let fixture = try makeFixture()
    let folder = fixture.directory.appendingPathComponent("fixture-images", isDirectory: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    // The folder is already there, so `replace` keeps the name and the extraction writes
    // into a directory it has no permission to write into.
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o500])
    let options = Options(suffix: "", folder: nil, replace: true)

    XCTAssertThrowsError(try ImageExtractor().extract(fixture.input, options: options)) { error in
      guard case ExtractError.writeFailed(let url, let underlying) = error else {
        return XCTFail("expected a write failure, got \(error)")
      }
      XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "fixture-images")
      XCTAssertTrue(
        error.localizedDescription.contains(url.path),
        "the message should name the file that could not be written")
      XCTAssertEqual((underlying as NSError).domain, NSCocoaErrorDomain)
      XCTAssertNotNil((error as? ExtractError)?.underlyingError)
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    XCTAssertTrue(files.isEmpty)
  }

  /// The alpha of every pixel of a written PNG, row by row.
  private func alphaChannel(of url: URL) throws -> [UInt8] {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    XCTAssertTrue(rendered)
    return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
  }

  private func makeFixture() throws -> (directory: URL, input: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = directory.appendingPathComponent("fixture.pdf")
    try FixturePDF.data().write(to: input)
    return (directory, input)
  }
}
