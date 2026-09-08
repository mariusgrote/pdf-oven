import CoreGraphics
import Foundation
import XCTest

@testable import PDFOvenKit

/// A one-page PDF that paints each of the given image XObjects once. Small enough to spell the
/// syntax out, which is the point: these dictionaries say things no real producer says, either
/// because they are hostile or because the pixels have to be countable by hand.
struct TinyPDF {
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

// MARK: - Running one of these through the extractor

extension XCTestCase {
  /// Hands the body the document's first image XObject. `PDFObject` borrows the document's
  /// storage, so the document has to outlive the call — hence the closure.
  func withFirstImage<T>(in pdf: TinyPDF, _ body: (PDFObject) throws -> T) throws -> T {
    let url = try writeTemporary(pdf)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
    let page = try XCTUnwrap(document.page(at: 1))
    let resources = PDFObject(dictionary: try XCTUnwrap(page.dictionary))["Resources"]
    let xobjects = try XCTUnwrap(resources?["XObject"])
    let image = try XCTUnwrap(xobjects[try XCTUnwrap(xobjects.keys().sorted().first)])
    return try withExtendedLifetime(document) { try body(image) }
  }

  /// Whether the decode ladder refuses the first image outright. The extractor may still
  /// rasterize the page for it — that is rung 3 doing its job, not the pixels being read.
  func isUnreadable(_ pdf: TinyPDF, preferOriginalEncoding: Bool = false) throws -> Bool {
    try withFirstImage(in: pdf) { stream in
      guard let facts = ImageDecoder.facts(of: stream) else { return true }
      switch ImageDecoder.decode(
        stream, facts: facts, resolver: { _ in nil },
        preferOriginalEncoding: preferOriginalEncoding)
      {
      case .unreadable: return true
      case .decoded: return false
      }
    }
  }

  /// Runs a full extraction with the size filters turned down, so nothing is dropped for being
  /// small and every skip is a decision the decoder made. Returns the files by name, since the
  /// output folder goes away with the temporary directory.
  func extractedFiles(of pdf: TinyPDF, preferOriginalEncoding: Bool = false) throws
    -> [(name: String, data: Data)]
  {
    let url = try writeTemporary(pdf)
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let options = ExtractOptions(
      includeMarkup: false, preferOriginalEncoding: preferOriginalEncoding, minPixelSize: 1,
      minByteSize: 1)
    let result = try ImageExtractor(extractOptions: options).extract(url, options: Options())
    let files = try FileManager.default.contentsOfDirectory(
      at: result.folder, includingPropertiesForKeys: nil)
    return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
      (name: $0.lastPathComponent, data: try Data(contentsOf: $0))
    }
  }

  func writeTemporary(_ pdf: TinyPDF) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-tiny-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tiny.pdf")
    try pdf.serialized().write(to: url)
    return url
  }
}
