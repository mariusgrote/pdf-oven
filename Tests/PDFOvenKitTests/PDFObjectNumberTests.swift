import CoreGraphics
import Foundation
import XCTest

@testable import PDFOvenKit

/// Numbers a file may hold that no `Int` can. CoreGraphics hands a `/Width` of
/// `99999999999999999999999999` over as the real `1e26`, and converting one of those to `Int`
/// traps — before any of the size checks downstream ever see it.
final class PDFObjectNumberTests: XCTestCase {
  func testRealsOutsideIntegerRangeAreNotNumbers() throws {
    for width in ["99999999999999999999999999", "-99999999999999999999999999"] {
      try withFirstImage(in: oneImage(width: width)) { image in
        XCTAssertNil(try XCTUnwrap(image["Width"]).integer, "\(width) should not be an integer")
      }
    }
  }

  /// The reason the real fallback exists in the first place: producers write whole numbers
  /// with a decimal point, and those still have to read as the number they are.
  func testWholeRealsStillReadAsIntegers() throws {
    try withFirstImage(in: oneImage(width: "64.0")) { image in
      XCTAssertEqual(try XCTUnwrap(image["Width"]).integer, 64)
    }
    try withFirstImage(in: oneImage(width: "64")) { image in
      XCTAssertEqual(try XCTUnwrap(image["Width"]).integer, 64)
    }
  }

  /// End to end: an unrepresentable `/Width` is an image with no facts, which the extractor
  /// skips like any other image it cannot read.
  func testUnrepresentableWidthIsSkippedNotFatal() throws {
    let pdf = oneImage(width: "99999999999999999999999999")
    try withFirstImage(in: pdf) { XCTAssertNil(ImageDecoder.facts(of: $0)) }
    XCTAssertEqual(try extractedFiles(of: pdf).count, 0)
  }

  private func oneImage(width: String) -> TinyPDF {
    TinyPDF(
      images: [
        TinyPDF.Image(
          dictionary: "/ColorSpace /DeviceGray /Width \(width) /Height 64 /BitsPerComponent 8",
          data: Data(repeating: 0x5A, count: 64 * 64))
      ])
  }
}
