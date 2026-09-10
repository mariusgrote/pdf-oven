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
  /// Retains hyperlink actions after baking. Disable to remove interactive links as well.
  public var preserveLinks: Bool
  /// Tests and non-app clients may supply an absolute qpdf path. The app always uses its
  /// bundled helper and never searches PATH.
  public var qpdfExecutable: URL?

  public init(
    method: FlatteningMethod = .redraw,
    optimize: Bool = false,
    preserveLinks: Bool = true,
    qpdfExecutable: URL? = nil
  ) {
    self.method = method
    self.optimize = optimize
    self.preserveLinks = preserveLinks
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
  case formStructureRemains
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
      return
        "The result still contains \(count) editable annotation\(count == 1 ? "" : "s"). Use Compatibility redraw instead."
    case .formFieldsRemain(let count):
      return
        "The result still contains \(count) editable form field\(count == 1 ? "" : "s"). Use Compatibility redraw instead."
    case .formStructureRemains:
      return "The result still contains a form dictionary. Use Compatibility redraw instead."
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
      try qpdf?.flatten(input: input, output: work.baked, preserveLinks: options.preserveLinks)
    case .pdfKit:
      try burnInWithPDFKit(source, output: work.baked, preserveLinks: options.preserveLinks)
    case .redraw:
      try redraw(source, output: work.baked)
      if options.preserveLinks {
        try restoreLinks(from: source, output: work.baked, transformed: true)
      }
    }
    if options.method != .redraw {
      let counts = try structuralCounts(in: work.baked, preserveLinks: options.preserveLinks)
      if counts.annotations > 0 || counts.hasAcroForm {
        let helper = try qpdf ?? QPDF(executable: options.qpdfExecutable)
        try helper.clean(
          input: work.baked, output: work.optimized, preserveLinks: options.preserveLinks)
        try FileManager.default.removeItem(at: work.baked)
        try FileManager.default.moveItem(at: work.optimized, to: work.baked)
      }
    }
    try validate(work.baked, expectedPages: pageCount, preserveLinks: options.preserveLinks)

    var chosen = work.baked
    var optimized = false
    if let qpdf, options.optimize {
      try qpdf.optimize(input: work.baked, output: work.optimized)
      try validate(work.optimized, expectedPages: pageCount, preserveLinks: options.preserveLinks)
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

  private static func burnInWithPDFKit(_ document: PDFDocument, output: URL, preserveLinks: Bool)
    throws
  {
    let links = (0..<document.pageCount).flatMap { index -> [(PDFPage, PDFAnnotation)] in
      guard let page = document.page(at: index) else { return [] }
      return page.annotations.filter { $0.type == "Link" }.map { (page, $0) }
    }
    // PDFKit burns links too; retain their original actions separately.
    if preserveLinks { for (page, link) in links { page.removeAnnotation(link) } }
    defer {
      if preserveLinks {
        for (page, link) in links where link.page == nil { page.addAnnotation(link) }
      }
    }
    let options: [PDFDocumentWriteOption: Any] = [
      .burnInAnnotationsOption: true,
      .saveImagesAsJPEGOption: false,
      .optimizeImagesForScreenOption: false,
    ]
    guard document.write(to: output, withOptions: options) else {
      throw BakeError.writeFailed(output)
    }
    if preserveLinks {
      for (page, link) in links { page.addAnnotation(link) }
      try restoreLinks(from: document, output: output, transformed: false)
    }
  }

  private static func restoreLinks(from source: PDFDocument, output: URL, transformed: Bool) throws
  {
    guard
      (0..<source.pageCount).contains(where: { index in
        source.page(at: index)?.annotations.contains(where: { $0.type == "Link" }) == true
      })
    else { return }
    let target = try open(output)
    func transform(_ page: PDFPage) -> CGAffineTransform {
      guard transformed, let ref = page.pageRef else { return .identity }
      return ref.getDrawingTransform(
        .cropBox,
        rect: CGRect(origin: .zero, size: renderedSize(of: page)), rotate: 0,
        preserveAspectRatio: true)
    }
    for index in 0..<source.pageCount {
      guard let page = source.page(at: index), let destinationPage = target.page(at: index) else {
        continue
      }
      for original in page.annotations where original.type == "Link" {
        let link: PDFAnnotation
        if transformed {
          // The redraw already painted the original appearance. Add only its clickable
          // region so rotated appearances and borders are neither moved nor painted twice.
          link = PDFAnnotation(
            bounds: original.bounds.applying(transform(page)), forType: .link,
            withProperties: nil)
          let border = PDFBorder()
          border.lineWidth = 0
          link.border = border
          link.color = .clear
          link.shouldDisplay = original.shouldDisplay
          link.shouldPrint = original.shouldPrint
          link.url = original.url
          link.action = original.action
        } else {
          guard let copy = original.copy() as? PDFAnnotation else { continue }
          link = copy
        }
        let destination = (original.action as? PDFActionGoTo)?.destination ?? original.destination
        if let destination, let sourcePage = destination.page {
          let destinationIndex = source.index(for: sourcePage)
          if let targetPage = target.page(at: destinationIndex) {
            let mapped = PDFDestination(
              page: targetPage, at: destination.point.applying(transform(sourcePage)))
            mapped.zoom = destination.zoom
            link.destination = mapped
            link.action = PDFActionGoTo(destination: mapped)
          }
        }
        destinationPage.addAnnotation(link)
      }
    }
    guard target.write(to: output) else { throw BakeError.writeFailed(output) }
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

  private static func validate(_ url: URL, expectedPages: Int, preserveLinks: Bool) throws {
    let document = try open(url)
    guard document.pageCount == expectedPages else {
      throw BakeError.pageCountChanged(expected: expectedPages, actual: document.pageCount)
    }
    let structure = try structuralCounts(in: url, preserveLinks: preserveLinks)
    guard structure.annotations == 0 else {
      throw BakeError.annotationsRemain(structure.annotations)
    }
    guard structure.formFields == 0 else {
      throw BakeError.formFieldsRemain(structure.formFields)
    }
    guard !structure.hasAcroForm else { throw BakeError.formStructureRemains }
  }

  private static func structuralCounts(in url: URL, preserveLinks: Bool) throws -> (
    annotations: Int, formFields: Int, hasAcroForm: Bool
  ) {
    guard let document = CGPDFDocument(url as CFURL) else { throw BakeError.cannotOpen(url) }
    var annotations = 0
    guard document.numberOfPages > 0 else { throw BakeError.emptyDocument(url) }
    for pageNumber in 1...document.numberOfPages {
      guard let page = document.page(at: pageNumber), let dictionary = page.dictionary else {
        throw BakeError.cannotOpen(url)
      }
      var pageAnnotations: CGPDFArrayRef?
      if CGPDFDictionaryGetArray(dictionary, "Annots", &pageAnnotations), let pageAnnotations {
        for index in 0..<CGPDFArrayGetCount(pageAnnotations) {
          var annotation: CGPDFDictionaryRef?
          if preserveLinks, CGPDFArrayGetDictionary(pageAnnotations, index, &annotation),
            let annotation, annotationSubtype(annotation) == "Link"
          {
            continue
          }
          annotations += 1
        }
      }
    }

    var formFields = 0
    var hasAcroForm = false
    if let catalog = document.catalog {
      var form: CGPDFDictionaryRef?
      if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form {
        hasAcroForm = true
        var fields: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(form, "Fields", &fields), let fields {
          formFields = CGPDFArrayGetCount(fields)
        }
      }
    } else {
      throw BakeError.cannotOpen(url)
    }
    return (annotations, formFields, hasAcroForm)
  }

  /// The new methods may remove annotations that have no usable appearance to paint. Refuse
  /// those inputs before writing, so a pin, note or other visible annotation cannot vanish.
  private static func firstAnnotationWithoutAppearance(in url: URL) throws
    -> (page: Int, subtype: String)?
  {
    guard let document = CGPDFDocument(url as CFURL) else { throw BakeError.cannotOpen(url) }
    guard document.numberOfPages > 0 else { throw BakeError.emptyDocument(url) }
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
        if isDeliberatelyInvisible(annotation)
          || ["Popup", "Link"].contains(annotationSubtype(annotation) ?? "")
        {
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

  func flatten(input: URL, output: URL, preserveLinks: Bool) throws {
    let prepared = output.appendingPathExtension("prepared.pdf")
    let flattened = output.appendingPathExtension("flattened.pdf")
    defer {
      try? FileManager.default.removeItem(at: prepared)
      try? FileManager.default.removeItem(at: flattened)
    }
    if preserveLinks {
      try patch(input: input, output: prepared) { objects in
        func hideLinks(_ object: Any) -> Any {
          if let array = object as? [Any] { return array.map(hideLinks) }
          guard var dictionary = object as? [String: Any] else { return object }
          if dictionary["/Subtype"] as? String == "/Link" {
            dictionary["/PDFOvenOriginalFlags"] = dictionary["/F"] ?? 0
            dictionary["/F"] = (dictionary["/F"] as? Int ?? 0) | 2
          }
          return dictionary.mapValues(hideLinks)
        }
        objects = objects.mapValues(hideLinks)
      }
    }
    try run([
      "--flatten-annotations=all", "--remove-acroform", "--",
      preserveLinks ? prepared.path : input.path, flattened.path,
    ])
    // qpdf may renumber objects; original flags travel on each link until cleanup.
    try clean(input: flattened, output: output, preserveLinks: preserveLinks)
  }

  func clean(input: URL, output: URL, preserveLinks: Bool) throws {
    try patch(input: input, output: output) { objects in
      func dictionary(_ object: Any) -> [String: Any]? {
        if let reference = object as? String {
          return (objects["obj:" + reference] as? [String: Any])?["value"] as? [String: Any]
        }
        return object as? [String: Any]
      }
      func restoreFlags(_ object: Any) -> Any {
        if let array = object as? [Any] { return array.map(restoreFlags) }
        guard var dictionary = object as? [String: Any] else { return object }
        if dictionary["/Subtype"] as? String == "/Link",
          let flags = dictionary.removeValue(forKey: "/PDFOvenOriginalFlags")
        {
          dictionary["/F"] = flags
        }
        return dictionary.mapValues(restoreFlags)
      }
      objects = objects.mapValues(restoreFlags)
      for key in Array(objects.keys) {
        guard var wrapper = objects[key] as? [String: Any],
          var value = wrapper["value"] as? [String: Any]
        else { continue }
        if value["/Type"] as? String == "/Catalog" { value.removeValue(forKey: "/AcroForm") }
        if let annotationValue = value["/Annots"] {
          let annotations: [Any]?
          if let reference = annotationValue as? String {
            annotations = (objects["obj:" + reference] as? [String: Any])?["value"] as? [Any]
          } else {
            annotations = annotationValue as? [Any]
          }
          if let annotations {
            value["/Annots"] = annotations.filter { object in
              guard let annotation = dictionary(object) else { return true }
              let subtype = annotation["/Subtype"] as? String
              if subtype == "/Link" { return preserveLinks }
              let flags = annotation["/F"] as? Int ?? 0
              return subtype != "/Popup" && flags & 3 == 0
            }
          }
        }
        wrapper["value"] = value
        objects[key] = wrapper
      }
    }
  }

  private func patch(input: URL, output: URL, edit: (inout [String: Any]) -> Void) throws {
    let data = try run(["--json-output=2", "--json-stream-data=none", "--", input.path])
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sections = json["qpdf"] as? [Any], sections.count == 2,
      var objects = sections[1] as? [String: Any]
    else { throw BakeError.qpdfFailed(-1, "Invalid structural JSON from qpdf.") }
    edit(&objects)
    // Stream dictionaries are unchanged and intentionally omitted: only dictionary objects
    // are patched, so qpdf retains the original encoded vector and image streams.
    objects = objects.filter { ($0.value as? [String: Any])?["value"] != nil }
    let update = output.appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: update) }
    try JSONSerialization.data(withJSONObject: ["qpdf": [sections[0], objects]])
      .write(to: update)
    try run(["--update-from-json=" + update.path, "--", input.path, output.path])
  }

  func optimize(input: URL, output: URL) throws {
    try run([
      "--object-streams=generate", "--recompress-flate", "--compression-level=9", "--",
      input.path, output.path,
    ])
  }

  @discardableResult
  private func run(_ arguments: [String]) throws -> Data {
    let token = UUID().uuidString
    let stdout = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-qpdf-\(token).stdout")
    let stderr = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-qpdf-\(token).stderr")
    FileManager.default.createFile(atPath: stdout.path, contents: nil)
    FileManager.default.createFile(atPath: stderr.path, contents: nil)
    defer {
      try? FileManager.default.removeItem(at: stdout)
      try? FileManager.default.removeItem(at: stderr)
    }

    do {
      let outputFile = try FileHandle(forWritingTo: stdout)
      let errorFile = try FileHandle(forWritingTo: stderr)
      defer {
        try? outputFile.close()
        try? errorFile.close()
      }
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.standardOutput = outputFile
      process.standardError = errorFile
      try process.run()
      process.waitUntilExit()
      try outputFile.synchronize()
      try errorFile.synchronize()
      // qpdf uses status 3 for a completed operation with recoverable warnings.
      // The caller validates every produced PDF before installing it.
      guard process.terminationReason == .exit,
        process.terminationStatus == 0 || process.terminationStatus == 3
      else {
        let errors =
          (try? String(contentsOf: stderr, encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output =
          (try? String(contentsOf: stdout, encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = errors.isEmpty ? output : errors
        throw BakeError.qpdfFailed(process.terminationStatus, message)
      }
      return try Data(contentsOf: stdout)
    } catch let error as BakeError {
      throw error
    } catch {
      throw BakeError.qpdfFailed(-1, error.localizedDescription)
    }
  }
}
