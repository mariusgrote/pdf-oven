import CoreGraphics
import Foundation
import PDFKit

public enum FlatteningMethod: String, CaseIterable, Sendable {
  case preserveContent
  case pdfKit
  case redraw
}

public struct BakeOptions: Sendable {
  public var method: FlatteningMethod
  public var optimize: Bool
  /// Tests and non-app clients may supply an absolute qpdf path. The app always uses its
  /// bundled helper and never searches PATH.
  public var qpdfExecutable: URL?

  public init(
    method: FlatteningMethod = .redraw,
    optimize: Bool = false,
    qpdfExecutable: URL? = nil
  ) {
    self.method = method
    self.optimize = optimize
    self.qpdfExecutable = qpdfExecutable
  }
}

public struct BakeResult: Sendable {
  public let inputBytes: Int
  public let outputBytes: Int
  public let usedOptimizedFile: Bool
}

public enum BakeError: LocalizedError {
  case cannotOpen(URL)
  case passwordProtected(URL)
  case emptyDocument(URL)
  case contextFailed
  case writeFailed(URL)
  case qpdfUnavailable(URL)
  case qpdfFailed(Int32, String)
  case annotationHasNoAppearance(page: Int, subtype: String)
  case formAppearancesNeedUpdating
  case annotationsRemain(Int)
  case formFieldsRemain(Int)
  case pageCountChanged(expected: Int, actual: Int)
  case outputMatchesInput(URL)

  public var errorDescription: String? {
    switch self {
    case .cannotOpen(let url):
      return "\(url.lastPathComponent) is not a readable PDF."
    case .passwordProtected(let url):
      return "\(url.lastPathComponent) is password protected."
    case .emptyDocument(let url):
      return "\(url.lastPathComponent) has no pages."
    case .contextFailed:
      return "Could not create a PDF drawing context."
    case .writeFailed(let url):
      return "Could not write \(url.lastPathComponent)."
    case .qpdfUnavailable:
      return "The qpdf helper is missing from PDF Oven. Reinstall the app."
    case .qpdfFailed(let status, let message):
      let detail = message.isEmpty ? "No diagnostic was returned." : message
      return "qpdf stopped with status \(status): \(detail)"
    case .annotationHasNoAppearance(let page, let subtype):
      return
        "Page \(page) has a visible \(subtype) annotation without an appearance. "
        + "Flattening could remove it without painting it. Use Compatibility redraw instead."
    case .formAppearancesNeedUpdating:
      return
        "The form says its appearances are out of date. Resave it in a PDF editor or use "
        + "Compatibility redraw so field values are not baked incorrectly."
    case .annotationsRemain(let count):
      return "The result still contains \(count) editable annotation\(count == 1 ? "" : "s")."
    case .formFieldsRemain(let count):
      return "The result still contains \(count) editable form field\(count == 1 ? "" : "s")."
    case .pageCountChanged(let expected, let actual):
      return "The result has \(actual) pages; the input has \(expected)."
    case .outputMatchesInput(let url):
      return
        "The output resolves to the input \(url.lastPathComponent). The original was not changed."
    }
  }
}

public enum Baker {
  @discardableResult
  public static func bake(
    input: URL,
    to output: URL,
    options: BakeOptions = BakeOptions()
  ) throws -> BakeResult {
    guard !sameFile(input, output) else { throw BakeError.outputMatchesInput(input) }
    let source = try open(input)
    let pageCount = source.pageCount
    let inputBytes = fileSize(input)
    let qpdf =
      options.method == .preserveContent || options.optimize
      ? try QPDF(executable: options.qpdfExecutable) : nil

    let work = TemporaryOutputs(beside: output)
    defer { work.removeAll() }

    if options.method != .redraw,
      let missing = try firstAnnotationWithoutAppearance(in: input)
    {
      throw BakeError.annotationHasNoAppearance(page: missing.page, subtype: missing.subtype)
    }
    if options.method != .redraw, try formAppearancesNeedUpdating(in: input) {
      throw BakeError.formAppearancesNeedUpdating
    }

    switch options.method {
    case .preserveContent:
      try qpdf?.flatten(input: input, output: work.baked)
    case .pdfKit:
      try burnInWithPDFKit(source, output: work.baked)
    case .redraw:
      try redraw(source, output: work.baked)
    }
    try validate(work.baked, expectedPages: pageCount)

    var chosen = work.baked
    var optimized = false
    if let qpdf, options.optimize {
      try qpdf.optimize(input: work.baked, output: work.optimized)
      try validate(work.optimized, expectedPages: pageCount)
      if fileSize(work.optimized) < fileSize(work.baked) {
        chosen = work.optimized
        optimized = true
      }
    }

    try install(chosen, at: output)
    return BakeResult(
      inputBytes: inputBytes,
      outputBytes: fileSize(output),
      usedOptimizedFile: optimized
    )
  }

  private static func open(_ url: URL) throws -> PDFDocument {
    guard let document = PDFDocument(url: url) else { throw BakeError.cannotOpen(url) }
    guard !document.isLocked else { throw BakeError.passwordProtected(url) }
    guard document.pageCount > 0 else { throw BakeError.emptyDocument(url) }
    return document
  }

  private static func burnInWithPDFKit(_ document: PDFDocument, output: URL) throws {
    let options: [PDFDocumentWriteOption: Any] = [
      .burnInAnnotationsOption: true,
      .saveImagesAsJPEGOption: false,
      .optimizeImagesForScreenOption: false,
    ]
    guard document.write(to: output, withOptions: options) else {
      throw BakeError.writeFailed(output)
    }
  }

  /// Re-draws every page into a fresh PDF context. This is retained for files whose annotation
  /// appearances PDFKit must synthesize, but it can expand shared vector drawing resources.
  private static func redraw(_ document: PDFDocument, output: URL) throws {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: nil, auxiliaryInfo(of: document))
    else { throw BakeError.contextFailed }

    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      var box = CGRect(origin: .zero, size: renderedSize(of: page))
      guard box.width > 0, box.height > 0 else { continue }
      let pageInfo = [
        kCGPDFContextMediaBox as String: NSData(
          bytes: &box, length: MemoryLayout<CGRect>.size)
      ]
      context.beginPDFPage(pageInfo as CFDictionary)
      context.saveGState()
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
      context.endPDFPage()
    }
    context.closePDF()

    do {
      try data.write(to: output, options: .atomic)
    } catch {
      throw BakeError.writeFailed(output)
    }
  }

  private static func validate(_ url: URL, expectedPages: Int) throws {
    let document = try open(url)
    guard document.pageCount == expectedPages else {
      throw BakeError.pageCountChanged(expected: expectedPages, actual: document.pageCount)
    }
    let structure = try structuralCounts(in: url)
    guard structure.annotations == 0 else {
      throw BakeError.annotationsRemain(structure.annotations)
    }
    guard structure.formFields == 0 else {
      throw BakeError.formFieldsRemain(structure.formFields)
    }
  }

  private static func structuralCounts(in url: URL) throws -> (annotations: Int, formFields: Int) {
    guard let document = CGPDFDocument(url as CFURL) else { throw BakeError.cannotOpen(url) }
    var annotations = 0
    for pageNumber in 1...document.numberOfPages {
      guard let page = document.page(at: pageNumber), let dictionary = page.dictionary else {
        throw BakeError.cannotOpen(url)
      }
      var pageAnnotations: CGPDFArrayRef?
      if CGPDFDictionaryGetArray(dictionary, "Annots", &pageAnnotations), let pageAnnotations {
        annotations += CGPDFArrayGetCount(pageAnnotations)
      }
    }

    var formFields = 0
    if let catalog = document.catalog {
      var form: CGPDFDictionaryRef?
      if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form {
        var fields: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(form, "Fields", &fields), let fields {
          formFields = CGPDFArrayGetCount(fields)
        }
      }
    } else {
      throw BakeError.cannotOpen(url)
    }
    return (annotations, formFields)
  }

  /// The new methods may remove annotations that have no usable appearance to paint. Refuse
  /// those inputs before writing, so a pin, note or other visible annotation cannot vanish.
  private static func firstAnnotationWithoutAppearance(in url: URL) throws
    -> (page: Int, subtype: String)?
  {
    guard let document = CGPDFDocument(url as CFURL) else { throw BakeError.cannotOpen(url) }
    for pageNumber in 1...document.numberOfPages {
      guard let page = document.page(at: pageNumber), let pageDictionary = page.dictionary else {
        throw BakeError.cannotOpen(url)
      }
      var annotations: CGPDFArrayRef?
      guard CGPDFDictionaryGetArray(pageDictionary, "Annots", &annotations), let annotations else {
        continue
      }
      for index in 0..<CGPDFArrayGetCount(annotations) {
        var annotation: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else {
          continue
        }
        if isDeliberatelyInvisible(annotation) || annotationSubtype(annotation) == "Popup" {
          continue
        }
        if hasUsableNormalAppearance(annotation) { continue }
        let subtype = annotationSubtype(annotation) ?? "unknown"
        return (pageNumber, subtype)
      }
    }
    return nil
  }

  private static func formAppearancesNeedUpdating(in url: URL) throws -> Bool {
    guard let document = CGPDFDocument(url as CFURL), let catalog = document.catalog else {
      throw BakeError.cannotOpen(url)
    }
    var form: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else {
      return false
    }
    var needsAppearances: CGPDFBoolean = 0
    return CGPDFDictionaryGetBoolean(form, "NeedAppearances", &needsAppearances)
      && needsAppearances != 0
  }

  private static func hasUsableNormalAppearance(_ annotation: CGPDFDictionaryRef) -> Bool {
    guard hasRectangle(annotation, key: "Rect") else { return false }
    var appearance: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(annotation, "AP", &appearance), let appearance else {
      return false
    }
    var stream: CGPDFStreamRef?
    if CGPDFDictionaryGetStream(appearance, "N", &stream), let stream {
      var format = CGPDFDataFormat.raw
      guard let data = CGPDFStreamCopyData(stream, &format) else { return false }
      return CFDataGetLength(data) > 0 && appearanceHasBoundingBox(stream)
    }
    // Buttons select a named normal appearance from a state dictionary through /AS.
    var states: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(appearance, "N", &states), let states else {
      return false
    }
    var statePointer: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(annotation, "AS", &statePointer), let statePointer else {
      return false
    }
    var selected: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(states, statePointer, &selected), let selected else {
      return false
    }
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(selected, &format) else { return false }
    return CFDataGetLength(data) > 0 && appearanceHasBoundingBox(selected)
  }

  private static func appearanceHasBoundingBox(_ stream: CGPDFStreamRef) -> Bool {
    guard let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
    return hasRectangle(dictionary, key: "BBox")
  }

  private static func hasRectangle(_ dictionary: CGPDFDictionaryRef, key: String) -> Bool {
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, key, &array), let array,
      CGPDFArrayGetCount(array) == 4
    else { return false }
    for index in 0..<4 {
      var value: CGPDFReal = 0
      guard CGPDFArrayGetNumber(array, index, &value), value.isFinite else { return false }
    }
    return true
  }

  private static func annotationSubtype(_ annotation: CGPDFDictionaryRef) -> String? {
    var pointer: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(annotation, "Subtype", &pointer), let pointer else { return nil }
    return String(cString: pointer)
  }

  private static func isDeliberatelyInvisible(_ annotation: CGPDFDictionaryRef) -> Bool {
    var flags: CGPDFInteger = 0
    guard CGPDFDictionaryGetInteger(annotation, "F", &flags) else { return false }
    // PDF flags: Invisible (1) and Hidden (2). NoView annotations may still print.
    return flags & (1 | 2) != 0
  }

  private static func sameFile(_ first: URL, _ second: URL) -> Bool {
    let lhs = first.standardizedFileURL.resolvingSymlinksInPath()
    let rhs = second.standardizedFileURL.resolvingSymlinksInPath()
    if lhs == rhs { return true }
    guard FileManager.default.fileExists(atPath: rhs.path) else { return false }
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    let lhsID = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier as? AnyHashable
    let rhsID = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier as? AnyHashable
    return lhsID != nil && lhsID == rhsID
  }

  private static func install(_ temporary: URL, at output: URL) throws {
    let manager = FileManager.default
    do {
      if manager.fileExists(atPath: output.path) {
        _ = try manager.replaceItemAt(output, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: output)
      }
    } catch {
      throw BakeError.writeFailed(output)
    }
  }

  private static func fileSize(_ url: URL) -> Int {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return values?.fileSize ?? 0
  }

  /// `bounds(for:)` reports the unrotated box, so swap the axes for quarter-turn pages.
  private static func renderedSize(of page: PDFPage) -> CGSize {
    let crop = page.bounds(for: .cropBox).size
    let rotation = ((page.rotation % 360) + 360) % 360
    return rotation == 90 || rotation == 270
      ? CGSize(width: crop.height, height: crop.width) : crop
  }

  /// Carries the source document's metadata over to the re-drawn copy.
  private static func auxiliaryInfo(of document: PDFDocument) -> CFDictionary? {
    guard let attributes = document.documentAttributes else { return nil }
    let mapping: [(PDFDocumentAttribute, CFString)] = [
      (.titleAttribute, kCGPDFContextTitle),
      (.authorAttribute, kCGPDFContextAuthor),
      (.subjectAttribute, kCGPDFContextSubject),
      (.creatorAttribute, kCGPDFContextCreator),
    ]
    var info: [String: Any] = [:]
    for (source, destination) in mapping {
      if let value = attributes[source] as? String, !value.isEmpty {
        info[destination as String] = value
      }
    }
    if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String],
      !keywords.isEmpty
    {
      info[kCGPDFContextKeywords as String] = keywords
    }
    return info.isEmpty ? nil : (info as CFDictionary)
  }
}

private struct TemporaryOutputs {
  let baked: URL
  let optimized: URL

  init(beside output: URL) {
    let directory = output.deletingLastPathComponent()
    let token = UUID().uuidString
    baked = directory.appendingPathComponent(".pdfoven-\(token)-baked.pdf")
    optimized = directory.appendingPathComponent(".pdfoven-\(token)-optimized.pdf")
  }

  func removeAll() {
    try? FileManager.default.removeItem(at: baked)
    try? FileManager.default.removeItem(at: optimized)
  }
}

private struct QPDF {
  let executable: URL

  init(executable override: URL?) throws {
    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/qpdf", isDirectory: false)
    let candidate = override ?? bundled
    guard candidate.isFileURL, candidate.path.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: candidate.path)
    else { throw BakeError.qpdfUnavailable(candidate) }
    executable = candidate
  }

  func flatten(input: URL, output: URL) throws {
    try run(["--flatten-annotations=all", "--remove-acroform", "--", input.path, output.path])
  }

  func optimize(input: URL, output: URL) throws {
    try run([
      "--object-streams=generate", "--recompress-flate", "--compression-level=9", "--",
      input.path, output.path,
    ])
  }

  private func run(_ arguments: [String]) throws {
    let diagnostics = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-qpdf-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: diagnostics) }

    do {
      let file = try FileHandle(forWritingTo: diagnostics)
      defer { try? file.close() }
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.standardOutput = file
      process.standardError = file
      try process.run()
      process.waitUntilExit()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        try? file.synchronize()
        let message =
          (try? String(contentsOf: diagnostics, encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw BakeError.qpdfFailed(process.terminationStatus, message)
      }
    } catch let error as BakeError {
      throw error
    } catch {
      throw BakeError.qpdfFailed(-1, error.localizedDescription)
    }
  }
}
