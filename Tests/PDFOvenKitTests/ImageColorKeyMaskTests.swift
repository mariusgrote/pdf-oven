import CoreGraphics
import Foundation
import ImageIO
import PDFOvenFixtures
import XCTest

@testable import PDFOvenKit

/// `/Mask` as an array of numbers: a colour key. Each colour component gets an inclusive
/// `min max` pair, and a pixel whose original samples all fall inside their pair is
/// transparent. Every test here counts pixels, because the whole feature is one bit per pixel.
final class ImageColorKeyMaskTests: XCTestCase {
  /// The bounds are inclusive at both ends, and one component outside its range is enough to
  /// keep a pixel opaque.
  func testDeviceRGBColorKeyMasksTheNamedRange() throws {
    // Ranges: red 10…20, green 30…40, blue 50…60.
    let pixels: [(UInt8, UInt8, UInt8)] = [
      (10, 30, 50),  // both bounds at their minimum: inside
      (20, 40, 60),  // and at their maximum: inside
      (15, 35, 55),  // comfortably inside
      (9, 35, 55),  // red one under
      (21, 35, 55),  // red one over
      (15, 29, 55),  // green one under
      (15, 35, 61),  // blue one over
      (200, 210, 220),  // nowhere near
    ]
    var samples = Data()
    for (r, g, b) in pixels { samples.append(contentsOf: [r, g, b]) }
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceRGB /Width 4 /Height 2 /BitsPerComponent 8 "
            + "/Mask [10 20 30 40 50 60]",
          data: samples)
      ])

    let image = try onlyImage(of: pdf)
    XCTAssertEqual(image.alpha, [0, 0, 0, 255, 255, 255, 255, 255])
    // The pixels that survived are still the colours the stream stored.
    XCTAssertEqual(image.colour(at: 3), [9, 35, 55])
    XCTAssertEqual(image.colour(at: 7), [200, 210, 220])
  }

  func testDeviceGrayColorKeyMasksTheNamedRange() throws {
    let values: [UInt8] = [127, 128, 200, 201, 0, 255, 150, 199]
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceGray /Width 4 /Height 2 /BitsPerComponent 8 "
            + "/Mask [128 200]",
          data: Data(values))
      ])

    XCTAssertEqual(try onlyImage(of: pdf).alpha, [255, 0, 0, 255, 255, 255, 0, 0])
  }

  /// Sub-byte samples: the key still reads them out of the packed row.
  func testFourBitGrayColorKeyReadsPackedSamples() throws {
    // Two pixels to a byte: 2, 3 | 5, 6 | 8, 3 | 5, 15.
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceGray /Width 4 /Height 2 /BitsPerComponent 4 "
            + "/Mask [3 5]",
          data: Data([0x23, 0x56, 0x83, 0x5F]))
      ])

    XCTAssertEqual(try onlyImage(of: pdf).alpha, [255, 0, 0, 255, 255, 0, 0, 255])
  }

  /// For `/Indexed` the key names index values, not the colours the palette makes of them.
  func testIndexedColorKeyMasksIndexValues() throws {
    // Palette: red, green, blue, white — so index 3 is (255, 255, 255), a colour that is
    // nowhere near the masked range while its index sits right beside it.
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace [/Indexed /DeviceRGB 3 <FF000000FF000000FFFFFFFF>] "
            + "/Width 4 /Height 2 /BitsPerComponent 8 /Mask [1 2]",
          data: Data([0, 1, 2, 3, 3, 2, 1, 0]))
      ])

    let image = try onlyImage(of: pdf)
    XCTAssertEqual(image.alpha, [255, 0, 0, 255, 255, 0, 0, 255])
    XCTAssertEqual(image.colour(at: 0), [255, 0, 0])
    XCTAssertEqual(image.colour(at: 3), [255, 255, 255])
  }

  /// A JPEG with a colour key cannot be written as the stored file: JPEG has nowhere to put
  /// the transparency. The bytes are decoded and the key applied to what comes out.
  func testJPEGWithAColorKeyIsRebuiltRatherThanPassedThrough() throws {
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceRGB /Width 160 /Height 120 /BitsPerComponent 8 "
            + "/Filter /DCTDecode /Mask [0 255 0 255 0 255]",
          data: FixturePDF.embeddedJPEG())
      ])

    let files = try extractedFiles(of: pdf)
    XCTAssertEqual(files.count, 1)
    XCTAssertTrue(try XCTUnwrap(files.first).name.hasSuffix(".png"))
    // The key covers the whole of every range, so nothing is left visible.
    let image = try onlyImage(of: pdf)
    XCTAssertEqual(image.alpha.filter { $0 != 0 }, [])
  }

  /// `preferOriginalEncoding` still means the stored bytes, transparency or not.
  func testPreferOriginalEncodingKeepsTheStoredJPEG() throws {
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceRGB /Width 160 /Height 120 /BitsPerComponent 8 "
            + "/Filter /DCTDecode /Mask [0 255 0 255 0 255]",
          data: FixturePDF.embeddedJPEG())
      ])

    let files = try extractedFiles(of: pdf, preferOriginalEncoding: true)
    XCTAssertEqual(files.count, 1)
    let file = try XCTUnwrap(files.first)
    XCTAssertTrue(file.name.hasSuffix(".jpg"))
    XCTAssertEqual(file.data, FixturePDF.embeddedJPEG())
  }

  /// A `/Mask` array the spec does not allow is not a mask we can apply, and guessing at what
  /// was meant would write the wrong picture. The ladder drops to the rasterizer instead.
  func testMalformedColorKeyFallsBackInsteadOfDecoding() throws {
    let cases: [(String, String)] = [
      ("one bound short", "[10 20 30 40 50]"),
      ("one pair short", "[10 20 30 40]"),
      ("a pair too many", "[10 20 30 40 50 60 70 80]"),
      ("empty", "[]"),
      ("not whole numbers", "[10.5 20 30 40 50 60]"),
      ("minimum above maximum", "[30 20 30 40 50 60]"),
      ("above what 8 bits hold", "[0 256 30 40 50 60]"),
      ("below zero", "[-1 20 30 40 50 60]"),
      ("not numbers at all", "[(a) (b) 30 40 50 60]"),
    ]
    for (label, mask) in cases {
      let pdf = TinyPDF(
        images: [
          TinyPDF.Image(
            dictionary: "/ColorSpace /DeviceRGB /Width 4 /Height 2 /BitsPerComponent 8 "
              + "/Mask \(mask)",
            data: Data(repeating: 0x40, count: 24))
        ])
      XCTAssertTrue(try isUnreadable(pdf), "\(label) should not decode")
      // Rung 3 still has the page to render, so the extraction produces a file rather than
      // failing outright.
      XCTAssertEqual(try extractedFiles(of: pdf).count, 1, "\(label) should still write a file")
    }
  }

  /// The one the malformed cases are measured against: the same image with a valid key.
  func testAValidColorKeyDecodesFromTheStream() throws {
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceRGB /Width 4 /Height 2 /BitsPerComponent 8 "
            + "/Mask [10 20 30 40 50 60]",
          data: Data(repeating: 0x40, count: 24))
      ])
    XCTAssertFalse(try isUnreadable(pdf))
  }

  // MARK: - Reading the result back

  /// The pixels of the single PNG an extraction wrote, as premultiplied RGBA — which is all a
  /// bitmap context holds, so a masked-out pixel's colour is gone by design and only the
  /// opaque ones are worth comparing.
  private struct Pixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    var alpha: [UInt8] { stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] } }

    /// The red, green and blue of one pixel.
    func colour(at pixel: Int) -> [UInt8] {
      Array(rgba[(pixel * 4)..<(pixel * 4 + 3)])
    }
  }

  private func onlyImage(of pdf: TinyPDF) throws -> Pixels {
    let files = try extractedFiles(of: pdf)
    XCTAssertEqual(files.count, 1)
    let data = try XCTUnwrap(files.first).data
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    XCTAssertTrue(drawn)
    return Pixels(width: image.width, height: image.height, rgba: rgba)
  }
}
