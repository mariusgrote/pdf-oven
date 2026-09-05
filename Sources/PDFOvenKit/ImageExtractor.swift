import CoreGraphics
import CryptoKit
import Foundation

/// How much of the document an extraction pulls out, and what it leaves behind.
public struct ExtractOptions: Sendable {
  /// Also take images that arrived as markup: stamp annotations and image file attachments.
  public var includeMarkup: Bool
  /// Write one file per distinct image rather than one per time it is painted.
  public var dedupe: Bool
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
    preferOriginalEncoding: Bool = false,
    minPixelSize: Int = 32,
    minByteSize: Int = 1024
  ) {
    self.includeMarkup = includeMarkup
    self.dedupe = dedupe
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
  case writeFailed(URL, underlyingError: Error)

  public var errorDescription: String? {
    switch self {
    case .cannotOpen(let url): return "\(url.lastPathComponent) is not a readable PDF."
    case .passwordProtected(let url): return "\(url.lastPathComponent) is password protected."
    case .emptyDocument(let url): return "\(url.lastPathComponent) has no pages."
    case .folderFailed(let url): return "Could not create \(url.lastPathComponent)."
    case .writeFailed(let url, let underlying):
      return "Could not write \(url.path): \(underlying.localizedDescription)"
    }
  }

  /// The Cocoa error behind a failed write — no permission, a full disk — kept so the
  /// reason survives the trip to the caller.
  public var underlyingError: Error? {
    guard case .writeFailed(_, let underlying) = self else { return nil }
    return underlying
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
      try autoreleasepool {
        let scanner = PageImageScanner(page: page, number: number)
        for occurrence in scanner.contentImages() {
          try autoreleasepool { try session.take(occurrence, on: page) }
        }
        guard extractOptions.includeMarkup else { return }
        let markup = scanner.markupImages()
        for occurrence in markup.images {
          try autoreleasepool { try session.take(occurrence, on: page) }
        }
        for payload in markup.files { try session.take(payload) }
      }
    }
    if extractOptions.includeMarkup {
      for payload in EmbeddedFiles.images(in: document) { try session.take(payload) }
    }
    return session.result
  }
}

// MARK: - One document's extraction

/// Accumulates one document's extracted files and counts.
private final class Session {
  private let folder: URL
  private let options: ExtractOptions
  /// Content hashes of written files, for dedupe.
  private var writtenContent: Set<String> = []
  /// XObject identity to its decode outcome, so a logo on 50 pages decodes once.
  private var byStream: [Int: DecodeOutcome] = [:]
  /// XObjects already handled, so repeated uses do not produce another file.
  private var handledStreams: Set<Int> = []
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

  func take(_ occurrence: ImageOccurrence, on page: CGPDFPage) throws {
    let facts = occurrence.facts
    let identity = occurrence.stream.identity

    // A repeat of an image already dealt with needs no second file.
    if options.dedupe, let identity, handledStreams.contains(identity) {
      return
    }
    guard facts.width >= options.minPixelSize, facts.height >= options.minPixelSize else {
      skipped += 1
      markHandled(identity)
      return
    }

    let outcome = decode(occurrence)
    var image: DecodedImage
    switch outcome {
    case .decoded(let decoded):
      image = decoded
    case .unreadable:
      // Rung 3: nothing read the stored pixels, so render the page where the image sits.
      guard let fallback = Rasterizer.render(occurrence, on: page),
        let encoded = ImageDecoder.encodePNG(fallback)
      else {
        skipped += 1
        markHandled(identity)
        return
      }
      image = encoded
    }

    guard image.data.count >= options.minByteSize else {
      skipped += 1
      markHandled(identity)
      return
    }

    // Two different XObjects can still hold the same picture.
    let key = contentKey(image.data, facts: facts)
    if options.dedupe, writtenContent.contains(key) {
      markHandled(identity)
      return
    }

    let filename = unique(name(for: occurrence) + "." + image.fileExtension)
    try write(image.data, as: filename)
    markHandled(identity)
    writtenContent.insert(key)
  }

  private func decode(_ occurrence: ImageOccurrence) -> DecodeOutcome {
    if let identity = occurrence.stream.identity, let cached = byStream[identity] { return cached }
    let outcome = ImageDecoder.decode(
      occurrence.stream, facts: occurrence.facts, resolver: occurrence.resolveColorSpace,
      preferOriginalEncoding: options.preferOriginalEncoding)
    if let identity = occurrence.stream.identity { byStream[identity] = outcome }
    return outcome
  }

  /// Distinct image objects can still decode to the same bytes.
  private func contentKey(_ data: Data, facts: ImageFacts) -> String {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "\(digest)-\(facts.width)x\(facts.height)"
  }

  // MARK: Attached files

  func take(_ payload: FilePayload) throws {
    if let facts = payload.facts,
      facts.width < options.minPixelSize || facts.height < options.minPixelSize
    {
      skipped += 1
      return
    }
    guard payload.data.count >= options.minByteSize else {
      skipped += 1
      return
    }
    let digest = SHA256.hash(data: payload.data).map { String(format: "%02x", $0) }.joined()
    let facts = payload.facts
    let key =
      "file-\(digest)-\(facts?.width ?? 0)x\(facts?.height ?? 0)-\(facts?.bitsPerComponent ?? 0)"
    if options.dedupe, writtenContent.contains(key) { return }
    let filename = unique(name(for: payload) + "." + payload.fileExtension)
    try write(payload.data, as: filename)
    writtenContent.insert(key)
  }

  // MARK: Output

  /// A file we meant to write and could not is a failed extraction, not a skipped image:
  /// counting it as skipped would report success over a missing file.
  private func write(_ data: Data, as filename: String) throws {
    let destination = folder.appendingPathComponent(filename)
    do {
      try data.write(to: destination, options: .atomic)
    } catch {
      throw ExtractError.writeFailed(destination, underlyingError: error)
    }
    written += 1
    bytes += data.count
  }

  private func markHandled(_ identity: Int?) {
    if options.dedupe, let identity { handledStreams.insert(identity) }
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
/// image's placement is cut out of it. Anything painted over that area comes along too.
private enum Rasterizer {
  static func render(_ occurrence: ImageOccurrence, on page: CGPDFPage) -> CGImage? {
    guard let placement = occurrence.placement else { return nil }
    let area = CGRect(x: 0, y: 0, width: 1, height: 1).applying(placement)
    guard area.width > 0.01, area.height > 0.01 else { return nil }

    let facts = occurrence.facts
    let scale = max(CGFloat(facts.width) / area.width, CGFloat(facts.height) / area.height)
    // `/Width` and `/Height` come from the file, so the scaled extent can be absurd or not a
    // number at all. Reject it before `Int(_:)`, which traps rather than saturates.
    let scaledWidth = (area.width * scale).rounded()
    let scaledHeight = (area.height * scale).rounded()
    let ceiling = CGFloat(ImageGeometry.maxPixelCount)
    guard scaledWidth.isFinite, scaledHeight.isFinite,
      scaledWidth <= ceiling, scaledHeight <= ceiling
    else { return nil }
    let width = max(1, Int(scaledWidth))
    let height = max(1, Int(scaledHeight))
    guard ImageGeometry.pixelCount(width: width, height: height) != nil,
      let space = CGColorSpace(name: CGColorSpace.sRGB),
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
