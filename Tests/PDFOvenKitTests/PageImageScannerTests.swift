import CoreGraphics
import Foundation
import PDFOvenFixtures
import XCTest

@testable import PDFOvenKit

/// The page-dictionary lookups the scanner starts from. `CGPDFPage.dictionary` is optional, and
/// the scanner has to survive it being `nil` rather than trap on a damaged document.
///
/// No fixture can produce that page: CoreGraphics validates the page tree when it opens the
/// file, so a `/Kids` entry that is an integer, an array, a name, a stream, a free object or a
/// dangling reference makes `CGPDFDocument(_:)` return `nil` outright — the document never
/// opens, and `document.page(at:)` therefore never hands out a page whose dictionary is
/// missing. The `nil` handle is reachable only through the lookups themselves, so they are
/// what these tests exercise.
final class PageImageScannerTests: XCTestCase {
  func testPageWithoutDictionaryHasNoResourcesOrAnnotations() {
    XCTAssertNil(PageImageScanner.resources(of: nil))
    XCTAssertTrue(PageImageScanner.annotations(of: nil).isEmpty)
  }

  /// A page that does have a dictionary still reads the same as before.
  func testPageDictionaryStillYieldsItsResourcesAndAnnotations() throws {
    try withDocument(FixturePDF.data()) { document in
      let first = try XCTUnwrap(XCTUnwrap(document.page(at: 1)).dictionary)
      let resources = try XCTUnwrap(PageImageScanner.resources(of: first))
      XCTAssertFalse(try XCTUnwrap(resources["XObject"]).keys().isEmpty)
      XCTAssertTrue(PageImageScanner.annotations(of: first).isEmpty)

      // Page 3 is the one the fixture hangs a stamp and a file attachment off.
      let annotated = try XCTUnwrap(XCTUnwrap(document.page(at: 3)).dictionary)
      let annots = PageImageScanner.annotations(of: annotated)
      XCTAssertEqual(annots.count, 2)
      XCTAssertEqual(annots.first?["Subtype"]?.name, "Stamp")
    }
  }

  /// `/Annots` that is not an array is as good as absent, and the scanner reports no markup.
  func testAnnotationsThatAreNotAnArrayAreIgnored() throws {
    try withDocument(onePage(annots: "/Annots 42")) { document in
      let page = try XCTUnwrap(document.page(at: 1))
      XCTAssertTrue(PageImageScanner.annotations(of: page.dictionary).isEmpty)
      let markup = PageImageScanner(page: page, number: 1).markupImages()
      XCTAssertTrue(markup.images.isEmpty)
      XCTAssertTrue(markup.files.isEmpty)
    }
  }

  func testPageWithoutAnnotationsReportsNoMarkup() throws {
    try withDocument(onePage(annots: "")) { document in
      let page = try XCTUnwrap(document.page(at: 1))
      let markup = PageImageScanner(page: page, number: 1).markupImages()
      XCTAssertTrue(markup.images.isEmpty)
      XCTAssertTrue(markup.files.isEmpty)
    }
  }

  // MARK: - Harness

  /// `PDFObject` borrows the document's storage, so the document has to outlive the body.
  private func withDocument(_ bytes: Data, _ body: (CGPDFDocument) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-scanner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("page.pdf")
    try bytes.write(to: url)
    let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
    try withExtendedLifetime(document) { try body(document) }
  }

  /// A one-page document with nothing on it but whatever `/Annots` is handed in.
  private func onePage(annots: String) -> Data {
    let bodies = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \(annots) >>",
    ]
    var output = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
    var offsets: [Int] = []
    for (index, body) in bodies.enumerated() {
      offsets.append(output.count)
      output.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
    }
    let start = output.count
    let count = bodies.count + 1
    output.append(Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8))
    for offset in offsets {
      output.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    output.append(
      Data("trailer\n<< /Size \(count) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
    return output
  }
}
