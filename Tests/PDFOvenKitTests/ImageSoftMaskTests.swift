import CoreGraphics
import Foundation
import ImageIO
import PDFOvenFixtures
import XCTest

@testable import PDFOvenKit

/// A JPEG whose transparency lives in a second stream. JPEG has nowhere to put an alpha
/// channel, so the choice the ladder makes is between a rebuilt PNG and no file at all: an
/// opaque copy of the stored bytes would be the one answer that is silently wrong.
final class ImageSoftMaskTests: XCTestCase {
  /// A readable `/SMask` costs the stream its rung-1 pass-through and buys it a PNG that
  /// actually carries the coverage.
  func testJPEGWithAReadableSoftMaskIsRebuiltAsAMaskedPNG() throws {
    let decoded = try XCTUnwrap(decodedFirstImage(of: maskedJPEG(mask: halfCoverage)))
    XCTAssertEqual(decoded.fileExtension, "png")

    // The mask is opaque on its left half, and smaller than the image it covers — which PDF
    // allows — so the edge between the halves is resampled and only the far sides are exact.
    let alpha = try alphaChannel(ofPNG: decoded.data, width: 160, height: 120)
    XCTAssertEqual(alpha[60 * 160 + 5], 255)
    XCTAssertEqual(alpha[60 * 160 + 155], 0)
  }

  /// The mask names eight samples and supplies three. Dropping to the rasterizer keeps the
  /// transparency the page was authored with; writing the JPEG through would lose it.
  func testJPEGWithAnUnreadableSoftMaskIsRefusedRatherThanPassedThrough() throws {
    let pdf = maskedJPEG(
      mask: Data([255, 255, 255]),
      dictionary: "/Type /XObject /Subtype /Image /Width 4 /Height 2 /BitsPerComponent 8 "
        + "/ColorSpace /DeviceGray")
    XCTAssertNil(try decodedFirstImage(of: pdf))
    XCTAssertTrue(try isUnreadable(pdf))
    // Rung 3 still has the page to render, so the extraction writes a file after all.
    XCTAssertFalse(try extractedFiles(of: pdf).isEmpty)
  }

  /// Nothing to rebuild, so the stored bytes go out as they are.
  func testJPEGWithoutAMaskKeepsTheStoredBytes() throws {
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceRGB /Width 160 /Height 120 /BitsPerComponent 8 "
            + "/Filter /DCTDecode",
          data: FixturePDF.embeddedJPEG())
      ])

    let decoded = try XCTUnwrap(decodedFirstImage(of: pdf))
    XCTAssertEqual(decoded.fileExtension, "jpg")
    XCTAssertEqual(decoded.data, FixturePDF.embeddedJPEG())
  }

  /// `preferOriginalEncoding` asks for the stored bytes, and a readable mask does not override
  /// it — the transparency is dropped on purpose, which is what the flag means.
  func testPreferOriginalEncodingKeepsTheStoredJPEGDespiteTheSoftMask() throws {
    let decoded = try XCTUnwrap(
      decodedFirstImage(of: maskedJPEG(mask: halfCoverage), preferOriginalEncoding: true))
    XCTAssertEqual(decoded.fileExtension, "jpg")
    XCTAssertEqual(decoded.data, FixturePDF.embeddedJPEG())
  }

  // MARK: - Building and reading one of these

  /// A 16 × 12 grey mask: fully opaque on the left half, fully transparent on the right.
  private var halfCoverage: Data {
    Data((0..<(16 * 12)).map { $0 % 16 < 8 ? 255 : 0 })
  }

  /// The fixture JPEG with an `/SMask` pointing at a second image XObject — object 6, the next
  /// one `TinyPDF` numbers after the image itself.
  private func maskedJPEG(
    mask: Data,
    dictionary: String = "/Type /XObject /Subtype /Image /Width 16 /Height 12 "
      + "/BitsPerComponent 8 /ColorSpace /DeviceGray"
  ) -> TinyPDF {
    TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceRGB /Width 160 /Height 120 /BitsPerComponent 8 "
            + "/Filter /DCTDecode /SMask 6 0 R",
          data: FixturePDF.embeddedJPEG()),
        TinyPDF.Image(dictionary: dictionary, data: mask),
      ])
  }

  /// What the ladder makes of the document's first image, or `nil` where it refuses it.
  private func decodedFirstImage(of pdf: TinyPDF, preferOriginalEncoding: Bool = false) throws
    -> DecodedImage?
  {
    try withFirstImage(in: pdf) { stream in
      guard let facts = ImageDecoder.facts(of: stream) else { return nil }
      switch ImageDecoder.decode(
        stream, facts: facts, resolver: { _ in nil },
        preferOriginalEncoding: preferOriginalEncoding)
      {
      case .decoded(let image): return image
      case .unreadable: return nil
      }
    }
  }

  /// The coverage of a PNG, one byte per pixel in row order.
  private func alphaChannel(ofPNG data: Data, width: Int, height: Int) throws -> [UInt8] {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, width)
    XCTAssertEqual(image.height, height)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    XCTAssertTrue(drawn)
    return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
  }
}
