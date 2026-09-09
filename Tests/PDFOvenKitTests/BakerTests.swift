import CoreGraphics
import Foundation
import XCTest

@testable import PDFOvenKit

final class BakerTests: XCTestCase {
  func testCompatibilityRedrawRemainsTheDefault() {
    XCTAssertEqual(BakeOptions().method, .redraw)
    XCTAssertFalse(BakeOptions().optimize)
  }

  func testNewMethodsFlattenVectorAppearanceWithoutCreatingImages() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("vector.pdf")
    try BakingPDF().data().write(to: input)

    let native = directory.appendingPathComponent("native.pdf")
    try Baker.bake(input: input, to: native, options: BakeOptions(method: .pdfKit))
    try assertStaticVectorPDF(native)

    let qpdf = try requireQPDF()
    let preserved = directory.appendingPathComponent("preserved.pdf")
    try Baker.bake(
      input: input,
      to: preserved,
      options: BakeOptions(method: .preserveContent, qpdfExecutable: qpdf)
    )
    try assertStaticVectorPDF(preserved)
  }

  func testLosslessOptimizationNeverKeepsALargerFile() throws {
    let qpdf = try requireQPDF()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("vector.pdf")
    try BakingPDF(repetitions: 300).data().write(to: input)

    let plain = directory.appendingPathComponent("plain.pdf")
    let optimized = directory.appendingPathComponent("optimized.pdf")
    let plainResult = try Baker.bake(
      input: input,
      to: plain,
      options: BakeOptions(method: .preserveContent, qpdfExecutable: qpdf)
    )
    let optimizedResult = try Baker.bake(
      input: input,
      to: optimized,
      options: BakeOptions(method: .preserveContent, optimize: true, qpdfExecutable: qpdf)
    )

    XCTAssertLessThanOrEqual(optimizedResult.outputBytes, plainResult.outputBytes)
    try assertStaticVectorPDF(optimized)
  }

  func testQpdfRemovesTheFormTreeAlongWithWidgetAnnotations() throws {
    let qpdf = try requireQPDF()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("form.pdf")
    try BakingPDF(hasForm: true).data().write(to: input)
    let output = directory.appendingPathComponent("form-baked.pdf")

    try Baker.bake(
      input: input,
      to: output,
      options: BakeOptions(method: .preserveContent, qpdfExecutable: qpdf)
    )

    let document = try XCTUnwrap(CGPDFDocument(output as CFURL))
    let catalog = try XCTUnwrap(document.catalog)
    var form: CGPDFDictionaryRef?
    XCTAssertFalse(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form))
    try assertStaticVectorPDF(output)
  }

  func testStaleFormAppearancesAreRejectedByBothNewMethods() throws {
    let qpdf = try requireQPDF()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("stale-form.pdf")
    try BakingPDF(hasForm: true, needsAppearances: true).data().write(to: input)

    for (method, executable) in [
      (FlatteningMethod.pdfKit, nil),
      (FlatteningMethod.preserveContent, qpdf),
    ] {
      let output = directory.appendingPathComponent("\(method.rawValue).pdf")
      XCTAssertThrowsError(
        try Baker.bake(
          input: input,
          to: output,
          options: BakeOptions(method: method, qpdfExecutable: executable)
        )
      ) { error in
        guard case BakeError.formAppearancesNeedUpdating = error else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
  }

  func testMissingAppearanceCannotSilentlyDisappear() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("missing-appearance.pdf")
    try BakingPDF(appearance: .none).data().write(to: input)

    let nativeOutput = directory.appendingPathComponent("native.pdf")
    let sentinel = Data("existing native output".utf8)
    try sentinel.write(to: nativeOutput)
    XCTAssertThrowsError(
      try Baker.bake(input: input, to: nativeOutput, options: BakeOptions(method: .pdfKit))
    ) { error in
      guard case BakeError.annotationHasNoAppearance = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: nativeOutput), sentinel)

    let qpdf = try requireQPDF()
    let qpdfOutput = directory.appendingPathComponent("qpdf.pdf")
    try sentinel.write(to: qpdfOutput)
    XCTAssertThrowsError(
      try Baker.bake(
        input: input,
        to: qpdfOutput,
        options: BakeOptions(method: .preserveContent, qpdfExecutable: qpdf)
      )
    ) { error in
      guard case BakeError.annotationHasNoAppearance = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: qpdfOutput), sentinel)
  }

  func testNewMethodsRejectMissingSelectedAppearanceState() throws {
    let qpdf = try requireQPDF()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("bad-state.pdf")
    try BakingPDF(appearance: .missingSelectedState).data().write(to: input)

    for (method, executable) in [
      (FlatteningMethod.pdfKit, nil),
      (FlatteningMethod.preserveContent, qpdf),
    ] {
      XCTAssertThrowsError(
        try Baker.bake(
          input: input,
          to: directory.appendingPathComponent("\(method.rawValue).pdf"),
          options: BakeOptions(method: method, qpdfExecutable: executable)
        )
      ) { error in
        guard case BakeError.annotationHasNoAppearance = error else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
  }

  func testNewMethodsRejectAppearanceWithoutRequiredGeometry() throws {
    let qpdf = try requireQPDF()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("missing-bbox.pdf")
    try BakingPDF(appearance: .missingBoundingBox).data().write(to: input)

    for (method, executable) in [
      (FlatteningMethod.pdfKit, nil),
      (FlatteningMethod.preserveContent, qpdf),
    ] {
      XCTAssertThrowsError(
        try Baker.bake(
          input: input,
          to: directory.appendingPathComponent("\(method.rawValue).pdf"),
          options: BakeOptions(method: method, qpdfExecutable: executable)
        )
      ) { error in
        guard case BakeError.annotationHasNoAppearance = error else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
  }

  func testInputAndSymlinkToInputAreProtected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("original.pdf")
    let original = BakingPDF().data()
    try original.write(to: input)

    XCTAssertThrowsError(
      try Baker.bake(input: input, to: input, options: BakeOptions(method: .redraw))
    ) { error in
      guard case BakeError.outputMatchesInput = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }

    let link = directory.appendingPathComponent("alias.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
    XCTAssertThrowsError(
      try Baker.bake(input: input, to: link, options: BakeOptions(method: .redraw))
    ) { error in
      guard case BakeError.outputMatchesInput = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: input), original)
  }

  func testQpdfWarningsAreFailuresAndDoNotReplaceOutput() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input.pdf")
    try BakingPDF().data().write(to: input)
    let output = directory.appendingPathComponent("output.pdf")
    let sentinel = Data("existing output".utf8)
    try sentinel.write(to: output)

    let helper = directory.appendingPathComponent("qpdf-warning")
    try Data("#!/bin/sh\necho malformed PDF >&2\nexit 3\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

    XCTAssertThrowsError(
      try Baker.bake(
        input: input,
        to: output,
        options: BakeOptions(method: .preserveContent, qpdfExecutable: helper)
      )
    ) { error in
      guard case BakeError.qpdfFailed(3, let message) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("malformed PDF"))
    }
    XCTAssertEqual(try Data(contentsOf: output), sentinel)
  }

  private func assertStaticVectorPDF(
    _ url: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let document = try XCTUnwrap(CGPDFDocument(url as CFURL), file: file, line: line)
    XCTAssertEqual(document.numberOfPages, 1, file: file, line: line)
    let page = try XCTUnwrap(document.page(at: 1), file: file, line: line)
    XCTAssertTrue(
      PageImageScanner(page: page, number: 1).contentImages().isEmpty, file: file, line: line)
    XCTAssertTrue(PageImageScanner.annotations(of: page.dictionary).isEmpty, file: file, line: line)
    let colors = try renderedColorCounts(page)
    XCTAssertGreaterThan(
      colors.dark, 100, "The original black drawing is missing", file: file, line: line)
    XCTAssertGreaterThan(
      colors.red, 100, "The red annotation appearance is missing", file: file, line: line)
  }

  private func renderedColorCounts(_ page: CGPDFPage) throws -> (dark: Int, red: Int) {
    let width = 200
    let height = 200
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    return try pixels.withUnsafeMutableBytes { storage in
      let context = try XCTUnwrap(
        CGContext(
          data: storage.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.drawPDFPage(page)

      let bytes = storage.bindMemory(to: UInt8.self)
      var dark = 0
      var red = 0
      for offset in stride(from: 0, to: bytes.count, by: 4) {
        let r = bytes[offset]
        let g = bytes[offset + 1]
        let b = bytes[offset + 2]
        if r < 80, g < 80, b < 80 { dark += 1 }
        if r > 120, g < 100, b < 100 { red += 1 }
      }
      return (dark, red)
    }
  }

  private func requireQPDF() throws -> URL {
    if let configured = ProcessInfo.processInfo.environment["PDFOVEN_TEST_QPDF"] {
      let executable = URL(fileURLWithPath: configured)
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw NSError(
          domain: "BakerTests",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "PDFOVEN_TEST_QPDF is not executable: \(configured)"
          ]
        )
      }
      return executable
    }
    let candidates = [
      "/usr/local/bin/qpdf",
      "/opt/homebrew/bin/qpdf",
    ].map { URL(fileURLWithPath: $0) }
    guard
      let executable = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    else {
      throw XCTSkip("Set PDFOVEN_TEST_QPDF to run qpdf integration tests")
    }
    return executable
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-baker-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct BakingPDF {
  enum Appearance {
    case stream
    case none
    case missingSelectedState
    case missingBoundingBox
  }

  var appearance: Appearance = .stream
  var hasForm = false
  var needsAppearances = false
  var repetitions = 1

  func data() -> Data {
    let catalog = "<< /Type /Catalog /Pages 2 0 R" + (hasForm ? " /AcroForm 7 0 R" : "") + " >>"
    let page =
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] "
      + "/Resources << >> /Contents 4 0 R /Annots [5 0 R] >>"
    let path = String(repeating: "10 10 m 190 190 l 10 190 m 190 10 l S\n", count: repetitions)
    let annotationType =
      hasForm ? "/Subtype /Widget /FT /Tx /T (Name) /V (Hello)" : "/Subtype /Stamp"
    let appearanceEntry: String
    switch appearance {
    case .stream:
      appearanceEntry = "/AP << /N 6 0 R >>"
    case .none:
      appearanceEntry = ""
    case .missingSelectedState:
      appearanceEntry = "/AP << /N << /On 6 0 R >> >> /AS /Off"
    case .missingBoundingBox:
      appearanceEntry = "/AP << /N 6 0 R >>"
    }
    let annotation =
      "<< /Type /Annot \(annotationType) /Rect [40 40 90 90] /F 4 \(appearanceEntry) >>"
    let appearanceStream = stream(
      dictionary: "/Type /XObject /Subtype /Form "
        + (appearance == .missingBoundingBox ? "" : "/BBox [0 0 50 50] ")
        + "/Resources << >>",
      data: Data("1 0 0 RG 3 w 2 2 46 46 re S 2 2 m 48 48 l S".utf8)
    )

    var bodies: [Data] = [
      Data(catalog.utf8),
      Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
      Data(page.utf8),
      stream(dictionary: "", data: Data(path.utf8)),
      Data(annotation.utf8),
      appearanceStream,
    ]
    if hasForm {
      let stale = needsAppearances ? " /NeedAppearances true" : ""
      bodies.append(Data("<< /Fields [5 0 R]\(stale) >>".utf8))
    }
    return serialize(bodies)
  }

  private func stream(dictionary: String, data: Data) -> Data {
    var result = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
    result.append(data)
    result.append(Data("\nendstream".utf8))
    return result
  }

  private func serialize(_ bodies: [Data]) -> Data {
    var output = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
    var offsets: [Int] = []
    for (index, body) in bodies.enumerated() {
      offsets.append(output.count)
      output.append(Data("\(index + 1) 0 obj\n".utf8))
      output.append(body)
      output.append(Data("\nendobj\n".utf8))
    }
    let start = output.count
    output.append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8))
    for offset in offsets {
      output.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    output.append(
      Data(
        "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8
      )
    )
    return output
  }
}
