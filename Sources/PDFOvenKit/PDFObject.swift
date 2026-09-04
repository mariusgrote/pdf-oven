import CoreGraphics
import Foundation

/// A thin Swift veneer over CoreGraphics' untyped PDF object graph.
///
/// PDFKit exposes no API for the image data a document stores, so image extraction has to read
/// the raw object graph through `CGPDFDocument` and friends. That API is C-shaped and untyped,
/// so it is wrapped once, here, and nothing else in the package touches `CGPDF*` directly.
struct PDFObject {
  private enum Storage {
    case object(CGPDFObjectRef)
    case dictionary(CGPDFDictionaryRef)
    case stream(CGPDFStreamRef)
  }

  private let storage: Storage

  init(_ object: CGPDFObjectRef) { storage = .object(object) }
  init(dictionary: CGPDFDictionaryRef) { storage = .dictionary(dictionary) }
  init(stream: CGPDFStreamRef) { storage = .stream(stream) }

  /// Looks a key up in this object's dictionary. Stream objects are looked up in their own
  /// dictionary, so `stream["/Width"]` reads the way the PDF spec talks about it.
  subscript(key: String) -> PDFObject? {
    guard let dictionary else { return nil }
    var value: CGPDFObjectRef?
    guard CGPDFDictionaryGetObject(dictionary, key, &value), let value else { return nil }
    return PDFObject(value)
  }

  var dictionary: CGPDFDictionaryRef? {
    switch storage {
    case .dictionary(let dictionary): return dictionary
    case .stream(let stream): return CGPDFStreamGetDictionary(stream)
    case .object(let object):
      var value: CGPDFDictionaryRef?
      if CGPDFObjectGetValue(object, .dictionary, &value) { return value }
      // A stream is a dictionary with bytes attached; treat it as one for lookups.
      return stream.flatMap(CGPDFStreamGetDictionary)
    }
  }

  var stream: CGPDFStreamRef? {
    switch storage {
    case .stream(let stream): return stream
    case .dictionary: return nil
    case .object(let object):
      var value: CGPDFStreamRef?
      return CGPDFObjectGetValue(object, .stream, &value) ? value : nil
    }
  }

  var array: [PDFObject]? {
    guard case .object(let object) = storage else { return nil }
    var value: CGPDFArrayRef?
    guard CGPDFObjectGetValue(object, .array, &value), let value else { return nil }
    return (0..<CGPDFArrayGetCount(value)).compactMap { index in
      var element: CGPDFObjectRef?
      guard CGPDFArrayGetObject(value, index, &element), let element else { return nil }
      return PDFObject(element)
    }
  }

  /// A `/Name` without its leading slash: `Image`, `DCTDecode`, `DeviceRGB`.
  var name: String? {
    guard case .object(let object) = storage else { return nil }
    var value: UnsafePointer<Int8>?
    guard CGPDFObjectGetValue(object, .name, &value), let value else { return nil }
    return String(cString: value)
  }

  var integer: Int? {
    guard case .object(let object) = storage else { return nil }
    var value: CGPDFInteger = 0
    if CGPDFObjectGetValue(object, .integer, &value) { return Int(value) }
    // Producers do write `/Width 612.0`; take the number rather than reject the image.
    var approximate: CGPDFReal = 0
    if CGPDFObjectGetValue(object, .real, &approximate) { return Int(approximate) }
    return nil
  }

  var real: CGFloat? {
    guard case .object(let object) = storage else { return nil }
    var value: CGPDFReal = 0
    if CGPDFObjectGetValue(object, .real, &value) { return value }
    return integer.map(CGFloat.init)
  }

  var boolean: Bool? {
    guard case .object(let object) = storage else { return nil }
    var value: CGPDFBoolean = 0
    return CGPDFObjectGetValue(object, .boolean, &value) ? value != 0 : nil
  }

  /// A PDF text string, decoded from PDFDocEncoding or UTF-16 as the file stored it.
  var string: String? {
    guard let value = pdfString, let text = CGPDFStringCopyTextString(value) else { return nil }
    return text as String
  }

  /// The raw bytes of a PDF string, for the ones that hold binary data rather than text
  /// (an `/Indexed` palette, say).
  var stringBytes: Data? {
    guard let value = pdfString, let pointer = CGPDFStringGetBytePtr(value) else { return nil }
    return Data(bytes: pointer, count: CGPDFStringGetLength(value))
  }

  private var pdfString: CGPDFStringRef? {
    guard case .object(let object) = storage else { return nil }
    var value: CGPDFStringRef?
    return CGPDFObjectGetValue(object, .string, &value) ? value : nil
  }

  /// Every key of this object's dictionary, in the order CoreGraphics happens to hand them
  /// over — which is unspecified, so callers that need determinism sort the result.
  func keys() -> [String] {
    guard let dictionary else { return [] }
    var result: [String] = []
    withUnsafeMutablePointer(to: &result) { pointer in
      CGPDFDictionaryApplyFunction(
        dictionary,
        { key, _, info in
          info?.assumingMemoryBound(to: [String].self).pointee.append(String(cString: key))
        }, pointer)
    }
    return result
  }

  /// The address of the underlying dictionary or stream. Two `PDFObject`s that resolve to the
  /// same indirect object share it, which is what cycle detection needs; it says nothing about
  /// whether two different objects hold the same bytes.
  var identity: Int? {
    if let stream { return unsafeBitCast(stream, to: Int.self) }
    if let dictionary { return unsafeBitCast(dictionary, to: Int.self) }
    return nil
  }
}
