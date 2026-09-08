import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import PDFOvenKit

/// Streams whose `/Width`, `/Height` or `/BitsPerComponent` have been tampered with. None of
/// them may trap, read out of bounds or allocate wildly; they have to come out as "no facts"
/// or as an image the extractor quietly skips.
final class ImageDecoderSafetyTests: XCTestCase {
  func testUndefinedBitDepthsHaveNoFacts() throws {
    for bits in [0, 3, 5, 9_223_372_036_854_775_807] {
      let pdf = TinyPDF(
        images: [
          TinyPDF.Image(
            dictionary: "/ColorSpace /DeviceGray /Width 64 /Height 64 /BitsPerComponent \(bits)",
            data: Data(repeating: 0x5A, count: 64 * 64))
        ])
      XCTAssertNil(try facts(of: pdf), "BitsPerComponent \(bits) should be rejected")
      XCTAssertEqual(try written(pdf), 0)
    }
  }

  func testNonPositiveDimensionsHaveNoFacts() throws {
    for (width, height) in [(0, 64), (64, 0), (-64, 64), (64, -64)] {
      let pdf = TinyPDF(
        images: [
          TinyPDF.Image(
            dictionary:
              "/ColorSpace /DeviceGray /Width \(width) /Height \(height) /BitsPerComponent 8",
            data: Data(repeating: 0x5A, count: 4096))
        ])
      XCTAssertNil(try facts(of: pdf), "\(width)x\(height) should be rejected")
    }
  }

  /// Dimensions that overflow `width * height`, overflow the packed row length, or merely sit
  /// above the 64 megapixel ceiling. The stream still has facts — the decode ladder is what
  /// has to refuse it — so the extractor reports a skip and writes nothing.
  func testOversizedDimensionsAreSkippedNotDecoded() throws {
    let cases: [(String, Int, Int, Int)] = [
      ("width * height overflows", 1 << 40, 1 << 40, 8),
      ("bytesPerRow overflows", 1 << 61, 4, 16),
      ("just over 64 megapixels", 8000, 8001, 8),
      ("absurd width", 9_223_372_036_854_775_807, 4, 8),
      ("absurd height", 4, 9_223_372_036_854_775_807, 8),
    ]
    for (label, width, height, bits) in cases {
      let pdf = TinyPDF(
        images: [
          TinyPDF.Image(
            dictionary:
              "/ColorSpace /DeviceRGB /Width \(width) /Height \(height) /BitsPerComponent \(bits)",
            data: Data(repeating: 0x5A, count: 4096))
        ])
      XCTAssertEqual(try written(pdf), 0, label)
    }
  }

  /// The same, for the paths that allocate a buffer of their own: a stencil `/ImageMask` and
  /// an `/Indexed` palette image.
  func testOversizedMaskAndIndexedImagesAreSkipped() throws {
    let mask = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ImageMask true /Width \(1 << 40) /Height \(1 << 40) /BitsPerComponent 1",
          data: Data(repeating: 0xF0, count: 4096))
      ])
    XCTAssertEqual(try written(mask), 0)

    let palette = (0..<256).map { String(format: "%02X%02X%02X", $0, 255 - $0, $0 / 2) }.joined()
    let indexed = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace [/Indexed /DeviceRGB 255 <\(palette)>] "
            + "/Width 8000 /Height 8001 /BitsPerComponent 8",
          data: Data(repeating: 0x11, count: 4096))
      ])
    XCTAssertEqual(try written(indexed), 0)
  }

  /// `/Indexed` indices are 1, 2, 4 or 8 bits. A 16-bit index would read past the row the
  /// row-length check cleared.
  func testSixteenBitIndexedImageIsNotDecoded() throws {
    let palette = (0..<256).map { String(format: "%02X%02X%02X", $0, 255 - $0, $0 / 2) }.joined()
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace [/Indexed /DeviceRGB 255 <\(palette)>] "
            + "/Width 64 /Height 64 /BitsPerComponent 16",
          data: Data(repeating: 0x11, count: 64 * 64 * 2))
      ])
    XCTAssertTrue(try isUnreadable(pdf))
  }

  /// A negative `/hival` would index the palette backwards.
  func testNegativeIndexedHighestValueIsNotDecoded() throws {
    let palette = (0..<256).map { String(format: "%02X%02X%02X", $0, 255 - $0, $0 / 2) }.joined()
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace [/Indexed /DeviceRGB -1 <\(palette)>] "
            + "/Width 64 /Height 64 /BitsPerComponent 8",
          data: Data(repeating: 0x11, count: 64 * 64))
      ])
    XCTAssertTrue(try isUnreadable(pdf))
  }

  /// The depths that are allowed still come out as pictures of the right size.
  func testEveryValidBitDepthStillDecodes() throws {
    for bits in [1, 2, 4, 8, 16] {
      let bytesPerRow = (64 * bits + 7) / 8
      var samples = Data()
      for index in 0..<(bytesPerRow * 64) { samples.append(UInt8((index &* 37) % 251)) }
      let pdf = TinyPDF(
        images: [
          TinyPDF.Image(
            dictionary:
              "/ColorSpace /DeviceGray /Width 64 /Height 64 /BitsPerComponent \(bits)",
            data: samples)
        ])
      let facts = try XCTUnwrap(try facts(of: pdf), "\(bits) bpc should have facts")
      XCTAssertEqual(facts.bitsPerComponent, bits)
      // Read from the stream, not rasterized off the page.
      XCTAssertFalse(try isUnreadable(pdf), "\(bits) bpc should decode")

      let files = try extract(pdf)
      XCTAssertEqual(files.count, 1, "\(bits) bpc should produce one file")
      let bytes = try XCTUnwrap(files.first)
      let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(image.width, 64)
      XCTAssertEqual(image.height, 64)
    }
  }

  /// The `/Indexed` and `/ImageMask` paths, at the depths each of them allows.
  func testIndexedAndMaskDepthsStillDecode() throws {
    let palette = (0..<256).map { String(format: "%02X%02X%02X", $0, 255 - $0, $0 / 2) }.joined()
    for bits in [1, 2, 4, 8] {
      let bytesPerRow = (64 * bits + 7) / 8
      var samples = Data()
      for index in 0..<(bytesPerRow * 64) { samples.append(UInt8((index &* 53) % 251)) }
      let pdf = TinyPDF(
        images: [
          TinyPDF.Image(
            dictionary: "/ColorSpace [/Indexed /DeviceRGB 255 <\(palette)>] "
              + "/Width 64 /Height 64 /BitsPerComponent \(bits)",
            data: samples)
        ])
      XCTAssertFalse(try isUnreadable(pdf), "indexed at \(bits) bpc should decode")
      let files = try extract(pdf)
      XCTAssertEqual(files.count, 1, "indexed at \(bits) bpc should produce one file")
    }

    var stencil = Data()
    for index in 0..<(8 * 64) { stencil.append(UInt8((index &* 29) % 251)) }
    let mask = TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ImageMask true /Width 64 /Height 64 /BitsPerComponent 1", data: stencil)
      ])
    XCTAssertFalse(try isUnreadable(mask))
    XCTAssertEqual(try extract(mask).count, 1)
  }

  // MARK: - Harness

  /// The facts of the first image in a one-image document.
  private func facts(of pdf: TinyPDF) throws -> ImageFacts? {
    try withFirstImage(in: pdf) { ImageDecoder.facts(of: $0) }
  }

  private func written(_ pdf: TinyPDF) throws -> Int {
    try extract(pdf).count
  }

  private func extract(_ pdf: TinyPDF) throws -> [Data] {
    try extractedFiles(of: pdf).map(\.data)
  }
}
