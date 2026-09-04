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
    XCTAssertEqual(files.filter { $0.lastPathComponent != "index.json" }.count, 8)
    XCTAssertEqual(
      try Data(contentsOf: result.folder.appendingPathComponent("p001-01.jpg")),
      FixturePDF.embeddedJPEG())

    let index = try manifest(in: result.folder)
    XCTAssertEqual(index["document"] as? String, "fixture.pdf")
    let images = try XCTUnwrap(index["images"] as? [[String: Any]])

    let logo = try XCTUnwrap(images.first { ($0["filename"] as? String) == "p001-03.png" })
    XCTAssertEqual(logo["pages"] as? [Int], FixturePDF.Expectation.logoPages)
    XCTAssertEqual(logo["source"] as? String, "page")
    XCTAssertEqual(logo["rasterized"] as? Bool, false)

    let spacer = try XCTUnwrap(images.first { ($0["width"] as? Int) == 4 })
    XCTAssertEqual(spacer["skipped"] as? Bool, true)
    XCTAssertEqual(spacer["reason"] as? String, "smaller than 32 px")

    let attachment = try XCTUnwrap(
      images.first { ($0["source"] as? String) == "attachment" })
    XCTAssertEqual(attachment["width"] as? Int, 96)
    XCTAssertEqual(attachment["height"] as? Int, 96)
    XCTAssertEqual(attachment["colorSpace"] as? String, "DeviceRGB")

    let writtenPageImage = try XCTUnwrap(
      images.first { ($0["filename"] as? String) == "p001-01.jpg" })
    XCTAssertEqual(
      Set(writtenPageImage.keys),
      Set([
        "bitsPerComponent", "bytes", "colorSpace", "filename", "filters", "height",
        "ordered", "originalEncoding", "pages", "rasterized", "skipped", "source", "width",
      ]))
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
    let images = try XCTUnwrap(try manifest(in: result.folder)["images"] as? [[String: Any]])
    XCTAssertFalse(images.contains { ($0["source"] as? String) == "stamp" })
    XCTAssertFalse(images.contains { ($0["source"] as? String) == "attachment" })
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

  private func manifest(in folder: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: folder.appendingPathComponent("index.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
