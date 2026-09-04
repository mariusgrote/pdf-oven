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
    XCTAssertEqual(files.count, 8)
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
    let imageURL = result.folder.appendingPathComponent("p001-02.png")
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
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
    let opaque = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 255 }.count
    XCTAssertEqual(opaque, FixturePDF.Expectation.opaquePixels)
  }

  func testOptionsCanKeepRepeatsAndExcludeMarkup() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let options = ExtractOptions(includeMarkup: false, dedupe: false)
    let result = try ImageExtractor(extractOptions: options).extract(
      fixture.input, options: Options())

    XCTAssertEqual(result.written, 8)
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

  private func makeFixture() throws -> (directory: URL, input: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = directory.appendingPathComponent("fixture.pdf")
    try FixturePDF.data().write(to: input)
    return (directory, input)
  }
}
