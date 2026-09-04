import CoreGraphics
import CryptoKit
import Foundation

/// How much of the document an extraction pulls out, and what it leaves behind.
public struct ExtractOptions: Sendable {
  /// Also take images that arrived as markup: stamp annotations and image file attachments.
  public var includeMarkup: Bool
  /// Write one file per distinct image rather than one per time it is painted.
  public var dedupe: Bool
  /// Write `index.json` describing everything found, including what was skipped.
  public var writeIndex: Bool
  /// Keep the stored JPEG bytes even when the image has a soft mask, instead of
  /// reconstructing it as a PNG with transparency.
  public var preferOriginalEncoding: Bool
  /// Images narrower or shorter than this are spacers, bullets and gradient strips.
  public var minPixelSize: Int
  /// Output smaller than this is not worth a file either.
  public var minByteSize: Int

  public init(
    includeMarkup: Bool = true,
    dedupe: Bool = true,
    writeIndex: Bool = true,
    preferOriginalEncoding: Bool = false,
    minPixelSize: Int = 32,
    minByteSize: Int = 1024
  ) {
    self.includeMarkup = includeMarkup
    self.dedupe = dedupe
    self.writeIndex = writeIndex
    self.preferOriginalEncoding = preferOriginalEncoding
    self.minPixelSize = minPixelSize
    self.minByteSize = minByteSize
  }
}

public struct ExtractResult: Sendable {
  public let folder: URL
  /// Files written.
  public let written: Int
  /// Images found but not written, including images removed by the size filters.
  public let skipped: Int
  /// Total size of everything written.
  public let bytes: Int
}

public enum ExtractError: LocalizedError {
  case cannotOpen(URL)
  case passwordProtected(URL)
  case emptyDocument(URL)
  case folderFailed(URL)

  public var errorDescription: String? {
    switch self {
    case .cannotOpen(let url): return "\(url.lastPathComponent) is not a readable PDF."
    case .passwordProtected(let url): return "\(url.lastPathComponent) is password protected."
    case .emptyDocument(let url): return "\(url.lastPathComponent) has no pages."
    case .folderFailed(let url): return "Could not create \(url.lastPathComponent)."
    }
  }
}

/// Pulls every embedded image out of a PDF as a file on disk: the stored bytes wherever the
/// document holds a real image file, a reconstructed PNG otherwise.
public struct ImageExtractor: PDFOperation {
  public let name = "Extract Images"
  public var extractOptions: ExtractOptions

  public init(extractOptions: ExtractOptions = ExtractOptions()) {
    self.extractOptions = extractOptions
  }

  /// `Options.suffix` is unused here — the output is a folder, always named `<stem>-images`.
  public func run(inputs: [URL], options: Options) throws -> [OperationResult] {
    try inputs.map { input in
      let result = try extract(input, options: options, protecting: inputs)
      let size = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return OperationResult(output: result.folder, inputBytes: size, outputBytes: result.bytes)
    }
  }

  public func extract(_ input: URL, options: Options, protecting others: [URL] = []) throws
    -> ExtractResult
  {
    guard let document = CGPDFDocument(input as CFURL) else { throw ExtractError.cannotOpen(input) }
    guard !document.isEncrypted || document.isUnlocked else {
      throw ExtractError.passwordProtected(input)
    }
    guard document.numberOfPages > 0 else { throw ExtractError.emptyDocument(input) }

    let folder = Destination.imagesFolder(
      for: input, folder: options.folder, replace: options.replace, protecting: others)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw ExtractError.folderFailed(folder)
    }

    let session = Session(folder: folder, options: extractOptions)
    for number in 1...document.numberOfPages {
      guard let page = document.page(at: number) else { continue }
      // A 600 DPI scan is gigabytes if the decoded buffers pile up behind us.
      autoreleasepool {
        let scanner = PageImageScanner(page: page, number: number)
        for occurrence in scanner.contentImages() {
          autoreleasepool { session.take(occurrence, on: page) }
        }
        guard extractOptions.includeMarkup else { return }
        let markup = scanner.markupImages()
        for occurrence in markup.images {
          autoreleasepool { session.take(occurrence, on: page) }
        }
        for payload in markup.files { session.take(payload) }
      }
    }
    if extractOptions.includeMarkup {
      for payload in EmbeddedFiles.images(in: document) { session.take(payload) }
    }
    try session.finish(document: input.lastPathComponent)
    return session.result
  }
}

// MARK: - One document's extraction

/// Accumulates one document's output: what was written, what was folded into an earlier file,
/// and what was left out and why.
private final class Session {
  private let folder: URL
  private let options: ExtractOptions
  private var entries: [IndexEntry] = []
  /// Content hash of the written bytes to the entry that holds them, for dedupe.
  private var byContent: [String: Int] = [:]
  /// XObject identity to its decode outcome, so a logo on 50 pages decodes once.
  private var byStream: [Int: DecodeOutcome] = [:]
  /// Entry index for an already-handled XObject, so repeats only add a page number.
  private var handledStream: [Int: Int] = [:]
  private var usedNames: Set<String> = []
  private(set) var written = 0
  private(set) var skipped = 0
  private(set) var bytes = 0

  init(folder: URL, options: ExtractOptions) {
    self.folder = folder
    self.options = options
  }

  var result: ExtractResult {
    ExtractResult(folder: folder, written: written, skipped: skipped, bytes: bytes)
  }

  // MARK: Image XObjects

  func take(_ occurrence: ImageOccurrence, on page: CGPDFPage) {
    let facts = occurrence.facts
    let identity = occurrence.stream.identity

    // A repeat of an image already dealt with: record the page and move on.
    if options.dedupe, let identity, let index = handledStream[identity] {
      add(page: occurrence.page, to: index)
      return
    }
    guard facts.width >= options.minPixelSize, facts.height >= options.minPixelSize else {
      skipped += 1
      note(
        IndexEntry(occurrence, skipped: true, reason: "smaller than \(options.minPixelSize) px"),
        stream: identity)
      return
    }

    let outcome = decode(occurrence)
    var image: DecodedImage
    var rasterized = false
    switch outcome {
    case .decoded(let decoded):
      image = decoded
    case .unreadable(let reason):
      // Rung 3: nothing read the stored pixels, so render the page where the image sits.
      guard let fallback = Rasterizer.render(occurrence, on: page),
        let encoded = ImageDecoder.encodePNG(fallback)
      else {
        skipped += 1
        note(IndexEntry(occurrence, skipped: true, reason: reason), stream: identity)
        return
      }
      image = encoded
      rasterized = true
    }

    guard image.data.count >= options.minByteSize else {
      skipped += 1
      note(
        IndexEntry(occurrence, skipped: true, reason: "under \(options.minByteSize) bytes"),
        stream: identity)
      return
    }

    // Two different XObjects can still hold the same picture.
    let key = contentKey(image.data, facts: facts)
    if options.dedupe, let index = byContent[key] {
      add(page: occurrence.page, to: index)
      if let identity { handledStream[identity] = index }
      return
    }

    let filename = unique(name(for: occurrence) + "." + image.fileExtension)
    guard write(image.data, as: filename) else {
      skipped += 1
      note(IndexEntry(occurrence, skipped: true, reason: "could not be written"), stream: identity)
      return
    }
    var entry = IndexEntry(occurrence, skipped: false, reason: nil)
    entry.filename = filename
    entry.bytes = image.data.count
    entry.rasterized = rasterized
    entry.originalEncoding = image.isOriginalEncoding
    note(entry, stream: identity)
    byContent[key] = entries.count - 1
  }

  private func decode(_ occurrence: ImageOccurrence) -> DecodeOutcome {
    if let identity = occurrence.stream.identity, let cached = byStream[identity] { return cached }
    let outcome = ImageDecoder.decode(
      occurrence.stream, facts: occurrence.facts, resolver: occurrence.resolveColorSpace,
      preferOriginalEncoding: options.preferOriginalEncoding)
    if let identity = occurrence.stream.identity { byStream[identity] = outcome }
    return outcome
  }

  /// Distinct images can decode to the same bytes only if they really are the same image, but
  /// the dimensions and colour space go into the key anyway — they are already in hand.
  private func contentKey(_ data: Data, facts: ImageFacts) -> String {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "\(digest)-\(facts.width)x\(facts.height)-\(facts.bitsPerComponent)-\(facts.colorSpace)"
  }

  // MARK: Attached files

  func take(_ payload: FilePayload) {
    if let facts = payload.facts,
      facts.width < options.minPixelSize || facts.height < options.minPixelSize
    {
      skipped += 1
      note(
        IndexEntry(
          payload, filename: nil, skipped: true, reason: "smaller than \(options.minPixelSize) px"))
      return
    }
    guard payload.data.count >= options.minByteSize else {
      skipped += 1
      note(
        IndexEntry(
          payload, filename: nil, skipped: true, reason: "under \(options.minByteSize) bytes"))
      return
    }
    let digest = SHA256.hash(data: payload.data).map { String(format: "%02x", $0) }.joined()
    let facts = payload.facts
    let key =
      "file-\(digest)-\(facts?.width ?? 0)x\(facts?.height ?? 0)-\(facts?.bitsPerComponent ?? 0)"
    if options.dedupe, let index = byContent[key] {
      add(page: payload.page, to: index)
      return
    }
    let filename = unique(name(for: payload) + "." + payload.fileExtension)
    guard write(payload.data, as: filename) else {
      skipped += 1
      note(IndexEntry(payload, filename: nil, skipped: true, reason: "could not be written"))
      return
    }
    note(IndexEntry(payload, filename: filename, skipped: false, reason: nil))
    byContent[key] = entries.count - 1
  }

  // MARK: Output

  private func write(_ data: Data, as filename: String) -> Bool {
    do {
      try data.write(to: folder.appendingPathComponent(filename), options: .atomic)
      written += 1
      bytes += data.count
      return true
    } catch {
      return false
    }
  }

  func finish(document: String) throws {
    guard options.writeIndex else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let manifest = IndexFile(document: document, images: entries)
    try encoder.encode(manifest).write(
      to: folder.appendingPathComponent("index.json"), options: .atomic)
  }

  private func note(_ entry: IndexEntry) { entries.append(entry) }

  private func note(_ entry: IndexEntry, stream identity: Int?) {
    entries.append(entry)
    if options.dedupe, let identity { handledStream[identity] = entries.count - 1 }
  }

  private func add(page: Int, to index: Int) {
    guard page > 0 else { return }
    guard !entries[index].pages.contains(page) else { return }
    entries[index].pages.append(page)
  }

  // MARK: Naming

  private func name(for occurrence: ImageOccurrence) -> String {
    switch occurrence.source {
    case .stamp:
      return String(format: "p%03d-a%02d-stamp", occurrence.page, occurrence.annotation ?? 1)
    default:
      return String(format: "p%03d-%02d", occurrence.page, occurrence.order)
    }
  }

  private func name(for payload: FilePayload) -> String {
    switch payload.source {
    case .attachment:
      return String(
        format: "p%03d-a%02d-attach-%@", payload.page, payload.annotation ?? payload.order,
        payload.name)
    default:
      return String(format: "embedded-%02d-%@", payload.order, payload.name)
    }
  }

  private func unique(_ filename: String) -> String {
    guard usedNames.contains(filename.lowercased()) else {
      usedNames.insert(filename.lowercased())
      return filename
    }
    let url = URL(fileURLWithPath: filename)
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    var counter = 2
    var candidate = "\(stem)-\(counter).\(ext)"
    while usedNames.contains(candidate.lowercased()) {
      counter += 1
      candidate = "\(stem)-\(counter).\(ext)"
    }
    usedNames.insert(candidate.lowercased())
    return candidate
  }
}

// MARK: - index.json

private struct IndexFile: Encodable {
  var document: String
  var images: [IndexEntry]
}

private struct IndexEntry: Encodable {
  var filename: String?
  var source: ImageSource
  var pages: [Int]
  var width: Int?
  var height: Int?
  var bitsPerComponent: Int?
  var colorSpace: String?
  var filters: [String]?
  var bytes: Int?
  /// The image was recovered by rendering the page rather than by reading its pixels, so it
  /// may include whatever else the page paints over that area.
  var rasterized = false
  var originalEncoding = false
  var skipped = false
  var reason: String?
  /// False when the page's content stream would not scan, so the order of the page's images
  /// is the resource dictionary's rather than the document's.
  var ordered = true

  init(_ occurrence: ImageOccurrence, skipped: Bool, reason: String?) {
    source = occurrence.source
    pages = [occurrence.page]
    width = occurrence.facts.width
    height = occurrence.facts.height
    bitsPerComponent = occurrence.facts.bitsPerComponent
    colorSpace = occurrence.facts.colorSpace
    filters = occurrence.facts.filters
    self.skipped = skipped
    self.reason = reason
    ordered = occurrence.ordered
  }

  init(_ payload: FilePayload, filename: String?, skipped: Bool, reason: String?) {
    self.filename = filename
    source = payload.source
    pages = payload.page > 0 ? [payload.page] : []
    bytes = skipped ? nil : payload.data.count
    width = payload.facts?.width
    height = payload.facts?.height
    bitsPerComponent = payload.facts?.bitsPerComponent
    colorSpace = payload.facts?.colorSpace
    filters = payload.facts?.filters
    self.skipped = skipped
    self.reason = reason
  }
}

// MARK: - Document-level attachments

/// The catalog's `/Names /EmbeddedFiles` name tree — files attached to the document rather
/// than to a page.
private enum EmbeddedFiles {
  static func images(in document: CGPDFDocument) -> [FilePayload] {
    guard let catalog = document.catalog else { return [] }
    guard let root = PDFObject(dictionary: catalog)["Names"]?["EmbeddedFiles"] else { return [] }
    var specs: [(String, PDFObject)] = []
    walk(root, into: &specs, depth: 0)
    var payloads: [FilePayload] = []
    for (name, spec) in specs {
      guard let embedded = spec["EF"]?["UF"] ?? spec["EF"]?["F"],
        let (data, _) = ImageDecoder.streamData(embedded),
        let sniffed = FileType.sniff(data)
      else { continue }
      let declared = spec["UF"]?.string ?? spec["F"]?.string ?? name
      payloads.append(
        FilePayload(
          data: data, name: FileType.sanitize(declared), fileExtension: sniffed, page: 0,
          order: payloads.count + 1, annotation: nil, source: .embeddedFile,
          facts: FileType.facts(data)))
    }
    return payloads
  }

  private static func walk(_ node: PDFObject, into specs: inout [(String, PDFObject)], depth: Int) {
    guard depth < 32 else { return }
    if let names = node["Names"]?.array {
      for index in stride(from: 0, to: names.count - 1, by: 2) {
        specs.append((names[index].string ?? "file", names[index + 1]))
      }
    }
    for kid in node["Kids"]?.array ?? [] { walk(kid, into: &specs, depth: depth + 1) }
  }
}

// MARK: - Rung 3: rasterizing

/// The last rung of the ladder. JBIG2, undecoded CCITT fax and tint-transform colour spaces
/// have no pixels we can read, so the page is rendered at the image's own resolution and the
/// image's placement is cut out of it. Fidelity drops — anything painted over that area comes
/// along — which is why the manifest flags it.
private enum Rasterizer {
  static func render(_ occurrence: ImageOccurrence, on page: CGPDFPage) -> CGImage? {
    guard let placement = occurrence.placement else { return nil }
    let area = CGRect(x: 0, y: 0, width: 1, height: 1).applying(placement)
    guard area.width > 0.01, area.height > 0.01 else { return nil }

    let facts = occurrence.facts
    let scale = max(CGFloat(facts.width) / area.width, CGFloat(facts.height) / area.height)
    let width = max(1, Int((area.width * scale).rounded()))
    let height = max(1, Int((area.height * scale).rounded()))
    guard width * height <= 64_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // `drawPDFPage` applies its own box-and-rotation transform; undo it so the placement
    // transform, which is expressed in the page's default user space, still means something.
    let box = page.getBoxRect(.mediaBox)
    let applied = page.getDrawingTransform(
      .mediaBox, rect: CGRect(origin: .zero, size: box.size), rotate: 0, preserveAspectRatio: true)
    let target = CGAffineTransform(translationX: -area.minX, y: -area.minY)
      .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    context.concatenate(applied.inverted().concatenating(target))
    context.drawPDFPage(page)
    return context.makeImage()
  }
}
