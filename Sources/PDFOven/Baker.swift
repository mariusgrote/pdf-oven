import CoreGraphics
import Foundation
import PDFKit

enum BakeError: LocalizedError {
  case cannotOpen(URL)
  case passwordProtected(URL)
  case emptyDocument(URL)
  case contextFailed
  case writeFailed(URL)

  var errorDescription: String? {
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
    }
  }
}

/// Re-draws every page of a PDF into a fresh PDF context. Annotations are painted
/// into the page content stream, so the result carries no editable annotation objects.
enum Baker {
  static func bake(input: URL, to output: URL) throws {
    guard let document = PDFDocument(url: input) else { throw BakeError.cannotOpen(input) }
    guard !document.isLocked else { throw BakeError.passwordProtected(input) }
    guard document.pageCount > 0 else { throw BakeError.emptyDocument(input) }

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

  /// `bounds(for:)` reports the unrotated box, so swap the axes for quarter-turn pages.
  private static func renderedSize(of page: PDFPage) -> CGSize {
    let crop = page.bounds(for: .cropBox).size
    let rotation = ((page.rotation % 360) + 360) % 360
    return rotation == 90 || rotation == 270
      ? CGSize(width: crop.height, height: crop.width) : crop
  }

  /// Carries the source document's metadata over to the baked copy.
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
