import Foundation
import PDFOvenFixtures
import XCTest

@testable import PDFOvenKit

/// What dedupe does to the counters. `ExtractResult.skipped` is every image the extraction
/// found and did not write, so a duplicate folded onto a file already written counts exactly
/// like an image dropped for being too small — once, where it was found.
final class ImageDedupeCountTests: XCTestCase {
  /// The same XObject painted three times on one page: one file, and the two repeats are
  /// skips of their own.
  func testRepeatedPaintingOfOneStreamCountsEveryRepeatAsSkipped() throws {
    let pdf = TinyPDF(images: [TinyPDF.Image(dictionary: rgb, data: pixels(seed: 1), paintings: 3)])
    let extraction = try extraction(of: pdf)

    XCTAssertEqual(extraction.result.written, 1)
    XCTAssertEqual(extraction.result.skipped, 2)
    XCTAssertEqual(extraction.files.count, 1)
  }

  /// Two XObjects the document stores separately but that hold the same picture. The first one
  /// is written; the second is caught by the content hash rather than by the stream identity,
  /// and counts just the same.
  func testDistinctStreamsWithTheSameContentCountTheDuplicateAsSkipped() throws {
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(dictionary: rgb, data: pixels(seed: 2)),
        TinyPDF.Image(dictionary: rgb, data: pixels(seed: 2)),
      ])
    let extraction = try extraction(of: pdf)

    XCTAssertEqual(extraction.result.written, 1)
    XCTAssertEqual(extraction.result.skipped, 1)
    XCTAssertEqual(extraction.files.count, 1)
  }

  /// Two file attachments carrying the same bytes under different names.
  func testIdenticalAttachmentsCountTheDuplicateAsSkipped() throws {
    let pdf = TinyPDF(
      images: [],
      attachments: [
        TinyPDF.File(name: "receipt.jpg", data: FixturePDF.embeddedJPEG()),
        TinyPDF.File(name: "receipt-copy.jpg", data: FixturePDF.embeddedJPEG()),
      ])
    let extraction = try extraction(of: pdf)

    XCTAssertEqual(extraction.result.written, 1)
    XCTAssertEqual(extraction.result.skipped, 1)
    XCTAssertEqual(extraction.files, ["p001-a01-attach-receipt.jpg"])
  }

  /// The same, for the catalog's `/Names /EmbeddedFiles` tree: files attached to the document
  /// rather than to a page.
  func testIdenticalEmbeddedFilesCountTheDuplicateAsSkipped() throws {
    let pdf = TinyPDF(
      images: [],
      embeddedFiles: [
        TinyPDF.File(name: "logo.jpg", data: FixturePDF.embeddedJPEG()),
        TinyPDF.File(name: "logo-again.jpg", data: FixturePDF.embeddedJPEG()),
      ])
    let extraction = try extraction(of: pdf)

    XCTAssertEqual(extraction.result.written, 1)
    XCTAssertEqual(extraction.result.skipped, 1)
    XCTAssertEqual(extraction.files, ["embedded-01-logo.jpg"])
  }

  /// Without dedupe every occurrence gets its own file, so no duplicate can be skipped: the
  /// repeats, the twin stream, the copied attachment and the copied embedded file are all
  /// written and the counter stays at zero.
  func testWithoutDedupeNothingIsSkippedForBeingADuplicate() throws {
    let pdf = TinyPDF(
      images: [
        TinyPDF.Image(dictionary: rgb, data: pixels(seed: 3), paintings: 2),
        TinyPDF.Image(dictionary: rgb, data: pixels(seed: 3)),
      ],
      attachments: [
        TinyPDF.File(name: "receipt.jpg", data: FixturePDF.embeddedJPEG()),
        TinyPDF.File(name: "receipt-copy.jpg", data: FixturePDF.embeddedJPEG()),
      ],
      embeddedFiles: [
        TinyPDF.File(name: "logo.jpg", data: FixturePDF.embeddedJPEG()),
        TinyPDF.File(name: "logo-again.jpg", data: FixturePDF.embeddedJPEG()),
      ])
    let extraction = try extraction(of: pdf, dedupe: false)

    XCTAssertEqual(extraction.result.written, 7)
    XCTAssertEqual(extraction.result.skipped, 0)
    XCTAssertEqual(extraction.files.count, 7)
  }

  private let rgb = "/ColorSpace /DeviceRGB /Width 8 /Height 8 /BitsPerComponent 8"

  /// Eight by eight pixels of noise, so two images built from different seeds cannot collide.
  private func pixels(seed: Int) -> Data {
    Data((0..<(8 * 8 * 3)).map { UInt8(($0 &* 37 &+ seed &* 101) & 0xFF) })
  }
}
