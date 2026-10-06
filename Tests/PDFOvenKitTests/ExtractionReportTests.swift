import Foundation
import XCTest

@testable import PDFOvenKit

final class ExtractionReportTests: XCTestCase {
  func testRepeatedUnreadableImageIsNotReportedAsDuplicate() throws {
    let pdf = TinyPDF(images: [
      TinyPDF.Image(
        dictionary: "/ColorSpace /DeviceRGB /Width 1099511627776 /Height 4 /BitsPerComponent 8",
        data: Data(repeating: 0x5A, count: 4096), paintings: 2)
    ])
    let result = try extraction(of: pdf).result
    XCTAssertEqual(result.written, 0)
    XCTAssertEqual(result.unreadable, 2)
    XCTAssertEqual(result.duplicates, 0)
    XCTAssertEqual(result.tooSmall, 0)
    XCTAssertEqual(result.skippedSummary, "2 unreadable")
    XCTAssertNotNil(result.warning)
  }

  func testInvalidImageFactsAreReportedAsUnreadable() throws {
    let pdf = TinyPDF(images: [
      TinyPDF.Image(
        dictionary: "/ColorSpace /DeviceRGB /Width 0 /Height 4 /BitsPerComponent 8",
        data: Data(repeating: 0x5A, count: 48))
    ])
    let result = try extraction(of: pdf).result
    XCTAssertEqual(result.unreadable, 1)
    XCTAssertEqual(result.skipped, 1)
    XCTAssertNotNil(result.warning)
  }

  func testRepeatedFilteredImageRetainsItsSizeReason() throws {
    let pdf = TinyPDF(images: [
      TinyPDF.Image(
        dictionary: "/ColorSpace /DeviceRGB /Width 8 /Height 8 /BitsPerComponent 8",
        data: Data(repeating: 0x5A, count: 192), paintings: 2)
    ])
    let input = try writeTemporary(pdf)
    defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
    let result = try ImageExtractor().extract(input, options: Options())
    XCTAssertEqual(result.tooSmall, 2)
    XCTAssertEqual(result.duplicates, 0)
    XCTAssertEqual(result.unreadable, 0)
    XCTAssertNil(result.warning)

    let unfiltered = try ImageExtractor(
      extractOptions: ExtractOptions(
        dedupe: false, minPixelSize: 0, minByteSize: 0)
    ).extract(input, options: Options())
    XCTAssertEqual(unfiltered.written, 2)
    XCTAssertEqual(unfiltered.skipped, 0)
  }

  func testEncodedByteFilterReportsTooSmall() throws {
    let pdf = TinyPDF(images: [
      TinyPDF.Image(
        dictionary: "/ColorSpace /DeviceRGB /Width 8 /Height 8 /BitsPerComponent 8",
        data: Data(repeating: 0x5A, count: 192))
    ])
    let input = try writeTemporary(pdf)
    defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
    let result = try ImageExtractor(
      extractOptions: ExtractOptions(
        minPixelSize: 0, minByteSize: 100000)
    ).extract(input, options: Options())
    XCTAssertEqual(result.tooSmall, 1)
    XCTAssertEqual(result.written, 0)
    XCTAssertNil(result.warning)
  }
}
