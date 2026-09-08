import CoreGraphics
import Foundation
import XCTest

@testable import PDFOvenKit

/// The arithmetic that stands between a manipulated `/Width`, `/Height` or `/BitsPerComponent`
/// and a trap, an out-of-bounds read, or an allocation the size of the machine.
final class ImageGeometryTests: XCTestCase {
  func testOnlyDefinedBitDepthsAreSupported() {
    for bits in [1, 2, 4, 8, 16] {
      XCTAssertTrue(ImageGeometry.isSupportedBitDepth(bits))
    }
    for bits in [0, 3, 5, 7, 12, 32, -8, Int.max] {
      XCTAssertFalse(ImageGeometry.isSupportedBitDepth(bits))
    }
  }

  func testIndexedImagesStopAtEightBits() {
    for bits in [1, 2, 4, 8] {
      XCTAssertTrue(ImageGeometry.isSupportedBitDepth(bits, indexed: true))
    }
    XCTAssertFalse(ImageGeometry.isSupportedBitDepth(16, indexed: true))
    XCTAssertFalse(ImageGeometry.isSupportedBitDepth(0, indexed: true))
  }

  func testPixelCountRejectsOverflowAndTheCeiling() {
    XCTAssertEqual(ImageGeometry.pixelCount(width: 8000, height: 8000), 64_000_000)
    // One row past the 64 megapixel ceiling.
    XCTAssertNil(ImageGeometry.pixelCount(width: 8000, height: 8001))
    XCTAssertNil(ImageGeometry.pixelCount(width: Int.max, height: 2))
    XCTAssertNil(ImageGeometry.pixelCount(width: 1 << 40, height: 1 << 40))
    XCTAssertNil(ImageGeometry.pixelCount(width: 0, height: 10))
    XCTAssertNil(ImageGeometry.pixelCount(width: -4, height: 10))
  }

  func testBytesPerRowRoundsUpAndRejectsOverflow() {
    XCTAssertEqual(ImageGeometry.bytesPerRow(width: 7, components: 1, bitsPerComponent: 1), 1)
    XCTAssertEqual(ImageGeometry.bytesPerRow(width: 9, components: 1, bitsPerComponent: 1), 2)
    XCTAssertEqual(ImageGeometry.bytesPerRow(width: 64, components: 3, bitsPerComponent: 8), 192)
    XCTAssertEqual(ImageGeometry.bytesPerRow(width: 64, components: 1, bitsPerComponent: 16), 128)

    // width * components, width * components * bits, and the +7 all have to be checked.
    XCTAssertNil(ImageGeometry.bytesPerRow(width: Int.max, components: 4, bitsPerComponent: 8))
    XCTAssertNil(ImageGeometry.bytesPerRow(width: 1 << 60, components: 1, bitsPerComponent: 16))
    XCTAssertNil(ImageGeometry.bytesPerRow(width: Int.max, components: 1, bitsPerComponent: 1))
    XCTAssertNil(ImageGeometry.bytesPerRow(width: 8, components: 1, bitsPerComponent: 0))
  }

  func testBufferSizesRejectOverflowAndOversize() {
    XCTAssertEqual(ImageGeometry.bufferSize(bytesPerRow: 192, height: 64), 12288)
    XCTAssertNil(ImageGeometry.bufferSize(bytesPerRow: Int.max, height: 3))
    XCTAssertNil(ImageGeometry.bufferSize(bytesPerRow: 10, height: 0))

    XCTAssertEqual(ImageGeometry.bufferSize(width: 64, height: 64, channels: 3), 12288)
    XCTAssertNil(ImageGeometry.bufferSize(width: 8000, height: 8001, channels: 3))
    XCTAssertNil(ImageGeometry.bufferSize(width: Int.max, height: Int.max, channels: 4))
  }

  func testProductAndSumReportOverflow() {
    XCTAssertEqual(ImageGeometry.product(3, 4), 12)
    XCTAssertNil(ImageGeometry.product(Int.max, 2))
    XCTAssertEqual(ImageGeometry.sum(3, 7), 10)
    XCTAssertNil(ImageGeometry.sum(Int.max, 7))
  }
}
