import CoreGraphics
import Foundation
import ImageIO

/// Where an extracted image came from.
public enum ImageSource: String, Codable, Sendable {
  case page
  case stamp
  case attachment
  case embeddedFile
}

/// One image XObject at one place in the document.
struct ImageOccurrence {
  var stream: PDFObject
  var facts: ImageFacts
  /// 1-based page number.
  var page: Int
  /// Position among the images of this page, in the order the page paints them.
  var order: Int
  var source: ImageSource
  /// 1-based index into the page's `/Annots`, for images that arrived as markup.
  var annotation: Int?
  /// The transform in force where the image is painted, in the page's default user space.
  /// Only the rasterizing fallback needs it.
  var placement: CGAffineTransform?
  /// False when the page's content stream could not be scanned and the images were found by
  /// walking the resource dictionary instead, where order is undefined.
  var ordered: Bool
  var resolveColorSpace: ImageDecoder.ColorSpaceResolver
}

/// An image that the document carries as a whole file rather than as page content: an image
/// file attachment, or an entry in the document's embedded files.
struct FilePayload {
  var data: Data
  /// The name the document gave it, already sanitized for use on disk.
  var name: String
  var fileExtension: String
  /// 1-based page number, or 0 for a document-level embedded file.
  var page: Int
  var order: Int
  var annotation: Int?
  var source: ImageSource
  var facts: ImageFacts?
}

/// Finds every image a page paints, in the order it paints them, plus the images that arrived
/// as markup. Holds the CoreGraphics content streams it created alive for its own lifetime,
/// because the resource objects handed out above point into them.
final class PageImageScanner {
  private struct Frame {
    var contentStream: CGPDFContentStreamRef
    var ctm: CGAffineTransform
    var saved: [CGAffineTransform] = []
  }

  private let page: CGPDFPage
  private let number: Int
  private var frames: [Frame] = []
  private var retained: [CGPDFContentStreamRef] = []
  /// Streams currently being recursed into, so a resource cycle terminates. Malformed PDFs
  /// really do contain them.
  private var recursing: Set<Int> = []
  private var found: [ImageOccurrence] = []
  private var source: ImageSource = .page
  private var annotation: Int?
  private var ordered = true

  init(page: CGPDFPage, number: Int) {
    self.page = page
    self.number = number
  }

  deinit {
    for stream in retained { CGPDFContentStreamRelease(stream) }
  }

  // MARK: - Entry points

  /// Every image the page's own content paints.
  func contentImages() -> [ImageOccurrence] {
    found = []
    source = .page
    annotation = nil
    ordered = true
    let contentStream = pageContentStream
    if !scan(contentStream, ctm: .identity) {
      // The scanner gave up partway. Fall back to the resource dictionary for anything it
      // missed, and tell the caller the order is no longer the document's.
      ordered = false
      let seen = Set(found.compactMap(\.stream.identity))
      dictionaryPass(
        resources: PDFObject(dictionary: page.dictionary!)["Resources"], skipping: seen)
      for index in found.indices { found[index].ordered = false }
    }
    return numbered(found)
  }

  /// Images carried by the page's annotations: stamp appearances, and image file attachments.
  func markupImages() -> (images: [ImageOccurrence], files: [FilePayload]) {
    guard let annots = PDFObject(dictionary: page.dictionary!)["Annots"]?.array else {
      return ([], [])
    }
    found = []
    var files: [FilePayload] = []
    for (index, annot) in annots.enumerated() {
      let subtype = annot["Subtype"]?.name
      // Popups duplicate their parent's content and never carry images of their own.
      guard subtype != "Popup" else { continue }
      annotation = index + 1
      switch subtype {
      case "Stamp":
        source = .stamp
        scanAppearance(of: annot)
      case "FileAttachment":
        if let payload = attachment(of: annot, order: files.count + 1) { files.append(payload) }
      default: continue
      }
    }
    annotation = nil
    return (numbered(found), files)
  }

  /// Created once and kept alive: the resource objects it hands out point into it.
  private lazy var pageContentStream: CGPDFContentStreamRef = {
    let stream = CGPDFContentStreamCreateWithPage(page)
    retained.append(stream)
    return stream
  }()

  // MARK: - Content stream walk

  private func scan(_ contentStream: CGPDFContentStreamRef, ctm: CGAffineTransform) -> Bool {
    frames.append(Frame(contentStream: contentStream, ctm: ctm))
    defer { frames.removeLast() }
    let scanner = CGPDFScannerCreate(
      contentStream, PageImageScanner.operatorTable,
      Unmanaged.passUnretained(self).toOpaque())
    let completed = CGPDFScannerScan(scanner)
    CGPDFScannerRelease(scanner)
    return completed
  }

  /// `Do` — the operator that actually paints an XObject. Every one of these is an image in
  /// document order, or a form to recurse into.
  fileprivate func paint(_ name: String) {
    guard let frame = frames.last,
      let object = CGPDFContentStreamGetResource(frame.contentStream, "XObject", name)
    else { return }
    let xobject = PDFObject(object)
    guard xobject.stream != nil else { return }

    switch xobject["Subtype"]?.name {
    case "Image":
      record(xobject, ctm: frame.ctm, in: frame.contentStream)
    case "Form":
      recurse(into: xobject, from: frame)
    default:
      return
    }
  }

  private func recurse(into form: PDFObject, from frame: Frame) {
    guard let handle = form.stream, let identity = form.identity,
      !recursing.contains(identity), let dictionary = form.dictionary
    else { return }
    recursing.insert(identity)
    defer { recursing.remove(identity) }
    // A form with no resources of its own still resolves names through its parent, so hand
    // CoreGraphics the form's own dictionary and let the lookup fall through.
    let resources = form["Resources"]?.dictionary ?? dictionary
    let child = CGPDFContentStreamCreateWithStream(handle, resources, frame.contentStream)
    retained.append(child)
    _ = scan(child, ctm: matrix(of: form).concatenating(frame.ctm))
  }

  fileprivate func save() {
    guard !frames.isEmpty else { return }
    frames[frames.count - 1].saved.append(frames[frames.count - 1].ctm)
  }

  fileprivate func restore() {
    guard var frame = frames.last, let previous = frame.saved.popLast() else { return }
    frame.ctm = previous
    frames[frames.count - 1] = frame
  }

  fileprivate func concatenate(_ transform: CGAffineTransform) {
    guard !frames.isEmpty else { return }
    frames[frames.count - 1].ctm = transform.concatenating(frames[frames.count - 1].ctm)
  }

  private func record(
    _ stream: PDFObject, ctm: CGAffineTransform, in contentStream: CGPDFContentStreamRef
  ) {
    guard let facts = ImageDecoder.facts(of: stream) else { return }
    found.append(
      ImageOccurrence(
        stream: stream, facts: facts, page: number, order: 0, source: source,
        annotation: annotation, placement: ctm, ordered: ordered,
        resolveColorSpace: { name in
          CGPDFContentStreamGetResource(contentStream, "ColorSpace", name).map(PDFObject.init)
        }))
  }

  /// The fallback for a page whose content stream will not scan: walk `/Resources /XObject`
  /// by key. Sorted so at least the output is stable between runs.
  private func dictionaryPass(resources: PDFObject?, skipping seen: Set<Int>) {
    guard let xobjects = resources?["XObject"] else { return }
    for key in xobjects.keys().sorted() {
      guard let xobject = xobjects[key], xobject.stream != nil,
        let identity = xobject.identity, !seen.contains(identity), !recursing.contains(identity)
      else { continue }
      switch xobject["Subtype"]?.name {
      case "Image":
        guard let facts = ImageDecoder.facts(of: xobject) else { continue }
        found.append(
          ImageOccurrence(
            stream: xobject, facts: facts, page: number, order: 0, source: source,
            annotation: annotation, placement: nil, ordered: false,
            resolveColorSpace: { name in resources?["ColorSpace"]?[name] }))
      case "Form":
        recursing.insert(identity)
        dictionaryPass(resources: xobject["Resources"], skipping: seen)
        recursing.remove(identity)
      default:
        continue
      }
    }
  }

  // MARK: - Annotations

  /// A stamp's `/AP /N` is either the appearance form itself or a dictionary of appearance
  /// states, in which case `/AS` names the one in use.
  private func scanAppearance(of annot: PDFObject) {
    guard let normal = annot["AP"]?["N"] else { return }
    var appearance = normal
    if normal.stream == nil {
      let states = normal.keys()
      let chosen = annot["AS"]?.name ?? (states.count == 1 ? states.first : nil)
      guard let chosen, let state = normal[chosen], state.stream != nil else { return }
      appearance = state
    }
    guard let handle = appearance.stream, let dictionary = appearance.dictionary else { return }
    let resources = appearance["Resources"]?.dictionary ?? dictionary
    // Parented on the page so a stamp that leans on the page's resources still resolves.
    let contentStream = CGPDFContentStreamCreateWithStream(handle, resources, pageContentStream)
    retained.append(contentStream)
    // The rasterizing fallback only needs to know roughly where this sits on the page.
    let placement = rect(of: annot) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    let ctm = CGAffineTransform(translationX: placement.minX, y: placement.minY)
      .scaledBy(x: max(placement.width, 1), y: max(placement.height, 1))
    _ = scan(contentStream, ctm: matrix(of: appearance).concatenating(ctm))
  }

  private func attachment(of annot: PDFObject, order: Int) -> FilePayload? {
    guard let embedded = annot["FS"]?["EF"]?["UF"] ?? annot["FS"]?["EF"]?["F"],
      let (data, _) = ImageDecoder.streamData(embedded),
      let sniffed = FileType.sniff(data)
    else { return nil }
    let declared = annot["FS"]?["UF"]?.string ?? annot["FS"]?["F"]?.string
    return FilePayload(
      data: data, name: FileType.sanitize(declared), fileExtension: sniffed, page: number,
      order: order, annotation: annotation, source: .attachment, facts: FileType.facts(data))
  }

  private func rect(of annot: PDFObject) -> CGRect? {
    guard let values = annot["Rect"]?.array?.compactMap(\.real), values.count == 4 else {
      return nil
    }
    return CGRect(
      x: min(values[0], values[2]), y: min(values[1], values[3]),
      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
  }

  private func matrix(of form: PDFObject) -> CGAffineTransform {
    guard let values = form["Matrix"]?.array?.compactMap(\.real), values.count == 6 else {
      return .identity
    }
    return CGAffineTransform(
      a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
  }

  private func numbered(_ occurrences: [ImageOccurrence]) -> [ImageOccurrence] {
    occurrences.enumerated().map { index, occurrence in
      var occurrence = occurrence
      occurrence.order = index + 1
      return occurrence
    }
  }

  // MARK: - Operator table

  private static let operatorTable: CGPDFOperatorTableRef = {
    let table = CGPDFOperatorTableCreate()!
    CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
      var name: UnsafePointer<Int8>?
      guard CGPDFScannerPopName(scanner, &name), let name, let info else { return }
      PageImageScanner.from(info).paint(String(cString: name))
    }
    CGPDFOperatorTableSetCallback(table, "q") { _, info in
      if let info { PageImageScanner.from(info).save() }
    }
    CGPDFOperatorTableSetCallback(table, "Q") { _, info in
      if let info { PageImageScanner.from(info).restore() }
    }
    CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
      // Operands come off the stack last-first.
      var values = [CGPDFReal](repeating: 0, count: 6)
      for index in stride(from: 5, through: 0, by: -1) {
        guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
      }
      guard let info else { return }
      PageImageScanner.from(info).concatenate(
        CGAffineTransform(
          a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]))
    }
    return table
  }()

  private static func from(_ info: UnsafeMutableRawPointer) -> PageImageScanner {
    Unmanaged<PageImageScanner>.fromOpaque(info).takeUnretainedValue()
  }
}

/// Recognises image files by their leading bytes, and makes names from a document safe to put
/// on disk. An embedded filename is attacker-controlled text and its extension proves nothing.
enum FileType {
  static func sniff(_ data: Data) -> String? {
    func matches(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
      guard data.count >= offset + bytes.count else { return false }
      let start = data.index(data.startIndex, offsetBy: offset)
      return Array(data[start..<data.index(start, offsetBy: bytes.count)]) == bytes
    }
    if matches([0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if matches([0xFF, 0xD8, 0xFF]) { return "jpg" }
    if matches(Array("GIF8".utf8)) { return "gif" }
    if matches([0x49, 0x49, 0x2A, 0x00]) || matches([0x4D, 0x4D, 0x00, 0x2A])
      || matches([0x49, 0x49, 0x2B, 0x00]) || matches([0x4D, 0x4D, 0x00, 0x2B])
    {
      return "tiff"
    }
    if matches([0x42, 0x4D]) { return "bmp" }
    if matches(Array("RIFF".utf8)) && matches(Array("WEBP".utf8), at: 8) { return "webp" }
    if matches(Array("ftyp".utf8), at: 4) {
      for brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"]
      where matches(Array(brand.utf8), at: 8) {
        return "heic"
      }
    }
    return nil
  }

  static func facts(_ data: Data) -> ImageFacts? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let model: String
    switch image.colorSpace?.model {
    case .monochrome: model = "DeviceGray"
    case .rgb: model = "DeviceRGB"
    case .cmyk: model = "DeviceCMYK"
    case .lab: model = "Lab"
    default: model = "unknown"
    }
    return ImageFacts(
      width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
      colorSpace: model, filters: [], isMask: false, hasSoftMask: image.alphaInfo != .none)
  }

  /// Strips everything that could make a name escape the output folder or hide there.
  static func sanitize(_ name: String?) -> String {
    let stem = (name.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
    let cleaned = String(
      String(stem.unicodeScalars.filter(allowed.contains))
        .drop(while: { $0 == "." || $0 == " " || $0 == "-" }))
    let base = URL(fileURLWithPath: cleaned.isEmpty ? "file" : cleaned)
      .deletingPathExtension().lastPathComponent
    return String((base.isEmpty ? "file" : base).prefix(60))
  }
}
