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

  /// Whether the decode ladder refuses the first image outright. The extractor may still
  /// rasterize the page for it — that is rung 3 doing its job, not the pixels being read.
  private func isUnreadable(_ pdf: TinyPDF) throws -> Bool {
    try withFirstImage(in: pdf) { stream in
      guard let facts = ImageDecoder.facts(of: stream) else { return true }
      switch ImageDecoder.decode(
        stream, facts: facts, resolver: { _ in nil }, preferOriginalEncoding: false)
      {
      case .unreadable: return true
      case .decoded: return false
      }
    }
  }

  /// Hands the body the document's first image XObject. `PDFObject` borrows the document's
  /// storage, so the document has to outlive the call — hence the closure.
  private func withFirstImage<T>(in pdf: TinyPDF, _ body: (PDFObject) throws -> T) throws -> T {
    let url = try write(pdf)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
    let page = try XCTUnwrap(document.page(at: 1))
    let resources = PDFObject(dictionary: try XCTUnwrap(page.dictionary))["Resources"]
    let xobjects = try XCTUnwrap(resources?["XObject"])
    let image = try XCTUnwrap(xobjects[try XCTUnwrap(xobjects.keys().sorted().first)])
    return try withExtendedLifetime(document) { try body(image) }
  }

  private func written(_ pdf: TinyPDF) throws -> Int {
    try extract(pdf).count
  }

  /// Runs a full extraction with the size filters turned down, so nothing is dropped for
  /// being small and every skip is a decision the hardening made. Returns the bytes written,
  /// since the output folder goes away with the temporary directory.
  private func extract(_ pdf: TinyPDF) throws -> [Data] {
    let url = try write(pdf)
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let options = ExtractOptions(includeMarkup: false, minPixelSize: 1, minByteSize: 1)
    let result = try ImageExtractor(extractOptions: options).extract(url, options: Options())
    let files = try FileManager.default.contentsOfDirectory(
      at: result.folder, includingPropertiesForKeys: nil)
    return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
      try Data(contentsOf: $0)
    }
  }

  private func write(_ pdf: TinyPDF) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-safety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("hostile.pdf")
    try pdf.serialized().write(to: url)
    return url
  }
}

/// A one-page PDF that paints each of the given image XObjects once. Small enough to spell the
/// syntax out, which is the point: these dictionaries have to say things no real producer says.
private struct TinyPDF {
  struct Image {
    let dictionary: String
    let data: Data
  }

  let images: [Image]

  func serialized() -> Data {
    var content = ""
    for index in images.indices {
      content += "q 100 0 0 100 20 \(20 + index * 110) cm /Im\(index) Do Q\n"
    }
    let names = images.indices.map { "/Im\($0) \(5 + $0) 0 R" }.joined(separator: " ")

    var bodies: [String: Data] = [:]
    bodies["1"] = Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)
    bodies["2"] = Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)
    bodies["3"] = Data(
      ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        + "/Resources << /XObject << \(names) >> >> >>").utf8)
    bodies["4"] = stream(dictionary: "", data: Data(content.utf8))
    for (index, image) in images.enumerated() {
      bodies["\(5 + index)"] = stream(
        dictionary: "/Type /XObject /Subtype /Image " + image.dictionary, data: image.data)
    }

    let count = 5 + images.count
    var output = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
    var offsets: [Int] = []
    for number in 1..<count {
      offsets.append(output.count)
      output.append(Data("\(number) 0 obj\n".utf8))
      output.append(bodies["\(number)"] ?? Data())
      output.append(Data("\nendobj\n".utf8))
    }
    let start = output.count
    output.append(Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8))
    for offset in offsets {
      output.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    output.append(
      Data("trailer\n<< /Size \(count) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
    return output
  }

  private func stream(dictionary: String, data: Data) -> Data {
    var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
    body.append(data)
    body.append(Data("\nendstream".utf8))
    return body
  }
}
