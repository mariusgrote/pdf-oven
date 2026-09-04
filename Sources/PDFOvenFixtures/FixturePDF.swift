import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds the PDF the image-extraction tests run against.
///
/// The file is assembled byte by byte rather than drawn with CoreGraphics, because the point of
/// the fixture is the *stored* encodings — a baseline JPEG, an indexed palette, a CMYK image, a
/// soft mask — and no drawing API lets you choose those.
///
/// It holds, in this order:
///
/// - page 1: a baseline JPEG, an RGB image with a soft mask, the logo
/// - page 2: an indexed-palette image, a CMYK image, a 4×4 spacer, the logo
/// - page 3: the logo, an image stamp annotation, a PNG file attachment
/// - page 4: rotated 90°, carrying one image
public enum FixturePDF {
  /// Every image the fixture stores, and what an extraction should make of it.
  public enum Expectation {
    /// Files a default extraction writes: JPEG, soft-masked PNG, indexed, CMYK, logo,
    /// stamp, attachment, rotated-page image. The 4×4 spacer is not among them.
    public static let writtenFiles = 8
    /// The logo is one XObject painted on three pages.
    public static let logoPages = [1, 2, 3]
    /// The soft-masked image is opaque over its left half.
    public static let softMaskSize = 128
    public static let opaquePixels = softMaskSize * softMaskSize / 2
  }

  public static func data() -> Data {
    let builder = Builder()
    let side = Expectation.softMaskSize

    let jpeg = jpegImage(width: 160, height: 120)
    let jpegRef = builder.reserve()
    builder.stream(
      jpegRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 160 /Height 120 "
        + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode",
      data: jpeg)

    // An RGB image plus the soft mask that gives it transparency: opaque on the left half.
    let masked = rgbPixels(side, side) { x, y in texture(x, y, seed: 1) }
    var coverage = [UInt8]()
    for index in 0..<(side * side) { coverage.append(index % side < side / 2 ? 255 : 0) }
    let maskRef = builder.reserve()
    builder.flateStream(
      maskRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 128 /Height 128 "
        + "/ColorSpace /DeviceGray /BitsPerComponent 8",
      data: Data(coverage))
    let maskedRef = builder.reserve()
    builder.flateStream(
      maskedRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 128 /Height 128 "
        + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask \(maskRef) 0 R",
      data: masked)

    var palette = [UInt8]()
    for index in 0..<256 {
      let (r, g, b) = texture(index, index &* 17, seed: 9)
      palette.append(contentsOf: [r, g, b])
    }
    var indices = [UInt8]()
    for index in 0..<(side * side) {
      let (r, _, _) = texture(index % side, index / side, seed: 7)
      indices.append(r)
    }
    let indexedRef = builder.reserve()
    builder.flateStream(
      indexedRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 128 /Height 128 "
        + "/ColorSpace [/Indexed /DeviceRGB 255 <\(palette.map { String(format: "%02X", $0) }.joined())>] "
        + "/BitsPerComponent 8",
      data: Data(indices))

    var cmyk = [UInt8]()
    for index in 0..<(side * side) {
      let (c, m, y) = texture(index % side, index / side, seed: 5)
      cmyk.append(contentsOf: [c, m, y, 10])
    }
    let cmykRef = builder.reserve()
    builder.flateStream(
      cmykRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 128 /Height 128 "
        + "/ColorSpace /DeviceCMYK /BitsPerComponent 8",
      data: Data(cmyk))

    // Below the 32 px threshold: a layout spacer, not a picture.
    let spacerRef = builder.reserve()
    builder.flateStream(
      spacerRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 4 /Height 4 "
        + "/ColorSpace /DeviceGray /BitsPerComponent 8",
      data: Data(repeating: 128, count: 16))

    let logoRef = builder.reserve()
    builder.flateStream(
      logoRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 128 /Height 128 "
        + "/ColorSpace /DeviceRGB /BitsPerComponent 8",
      data: rgbPixels(side, side) { x, y in texture(x, y, seed: 2) })

    let stampImageRef = builder.reserve()
    builder.flateStream(
      stampImageRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 128 /Height 128 "
        + "/ColorSpace /DeviceRGB /BitsPerComponent 8",
      data: rgbPixels(side, side) { x, y in texture(x, y, seed: 3) })

    let rotatedRef = builder.reserve()
    builder.flateStream(
      rotatedRef,
      dictionary: "/Type /XObject /Subtype /Image /Width 128 /Height 128 "
        + "/ColorSpace /DeviceRGB /BitsPerComponent 8",
      data: rgbPixels(side, side) { x, y in texture(x, y, seed: 4) })

    // The stamp's appearance stream, which is where its image actually lives.
    let stampFormRef = builder.reserve()
    builder.flateStream(
      stampFormRef,
      dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 100 100] "
        + "/Resources << /XObject << /ImStamp \(stampImageRef) 0 R >> >>",
      data: Data("q 100 0 0 100 0 0 cm /ImStamp Do Q".utf8))

    let attachmentBytes = pngImage(width: 96, height: 96)
    let attachmentRef = builder.reserve()
    builder.stream(
      attachmentRef, dictionary: "/Type /EmbeddedFile /Subtype /image#2Fpng",
      data: attachmentBytes)

    let stampAnnotRef = builder.reserve()
    let attachAnnotRef = builder.reserve()
    let pagesRef = builder.reserve()
    let pageRefs = (0..<4).map { _ in builder.reserve() }

    builder.define(
      stampAnnotRef,
      "<< /Type /Annot /Subtype /Stamp /Rect [60 500 160 600] /F 4 "
        + "/AP << /N \(stampFormRef) 0 R >> >>")
    builder.define(
      attachAnnotRef,
      "<< /Type /Annot /Subtype /FileAttachment /Rect [300 500 320 520] /F 4 "
        + "/FS << /Type /Filespec /F (receipt.png) /UF (receipt.png) "
        + "/EF << /F \(attachmentRef) 0 R >> >> >>")

    let contents: [(String, Data)] = [
      (
        "/ImJpeg \(jpegRef) 0 R /ImAlpha \(maskedRef) 0 R /ImLogo \(logoRef) 0 R",
        Data(
          """
          q 240 0 0 160 40 560 cm /ImJpeg Do Q
          q 128 0 0 128 40 380 cm /ImAlpha Do Q
          q 96 0 0 48 40 300 cm /ImLogo Do Q
          """.utf8)
      ),
      (
        "/ImIndexed \(indexedRef) 0 R /ImCmyk \(cmykRef) 0 R /ImSpacer \(spacerRef) 0 R "
          + "/ImLogo \(logoRef) 0 R",
        Data(
          """
          q 128 0 0 128 40 560 cm /ImIndexed Do Q
          q 128 0 0 128 220 560 cm /ImCmyk Do Q
          q 8 0 0 8 40 540 cm /ImSpacer Do Q
          q 96 0 0 48 40 300 cm /ImLogo Do Q
          """.utf8)
      ),
      ("/ImLogo \(logoRef) 0 R", Data("q 96 0 0 48 40 300 cm /ImLogo Do Q".utf8)),
      (
        "/ImRotated \(rotatedRef) 0 R",
        Data("q 128 0 0 128 40 560 cm /ImRotated Do Q".utf8)
      ),
    ]

    for (index, page) in pageRefs.enumerated() {
      let contentRef = builder.reserve()
      builder.flateStream(contentRef, dictionary: "", data: contents[index].1)
      var dictionary =
        "<< /Type /Page /Parent \(pagesRef) 0 R /MediaBox [0 0 612 792] "
        + "/Resources << /XObject << \(contents[index].0) >> >> /Contents \(contentRef) 0 R"
      if index == 2 {
        dictionary += " /Annots [\(stampAnnotRef) 0 R \(attachAnnotRef) 0 R]"
      }
      if index == 3 { dictionary += " /Rotate 90" }
      builder.define(page, dictionary + " >>")
    }

    builder.define(
      pagesRef,
      "<< /Type /Pages /Count \(pageRefs.count) "
        + "/Kids [\(pageRefs.map { "\($0) 0 R" }.joined(separator: " "))] >>")
    let catalogRef = builder.reserve()
    builder.define(catalogRef, "<< /Type /Catalog /Pages \(pagesRef) 0 R >>")
    return builder.serialize(catalog: catalogRef)
  }

  /// The JPEG bytes the fixture embeds, so a test can check that passthrough wrote exactly
  /// what the document stores.
  public static func embeddedJPEG() -> Data { jpegImage(width: 160, height: 120) }

  // MARK: - Pixels

  private static func rgbPixels(
    _ width: Int, _ height: Int, _ colour: (Int, Int) -> (UInt8, UInt8, UInt8)
  ) -> Data {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        let (r, g, b) = colour(x, y)
        bytes.append(contentsOf: [r, g, b])
      }
    }
    return Data(bytes)
  }

  /// Detailed enough that the encoders cannot compress it down to nothing — a flat gradient
  /// would come out under the default 1 KB floor and be filtered out of its own fixture.
  private static func detailed(width: Int, height: Int) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    for y in 0..<height {
      for x in 0..<width {
        let (r, g, b) = texture(x, y)
        context.setFillColor(
          red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
    return context.makeImage()
  }

  /// A cheap pseudo-random texture. Deterministic, so the fixture is byte-stable between runs.
  private static func texture(_ x: Int, _ y: Int, seed: Int = 0) -> (UInt8, UInt8, UInt8) {
    let hash = (x &* 73_856_093) ^ (y &* 19_349_663) ^ (seed &* 83_492_791)
    return (UInt8((hash >> 3) & 0xFF), UInt8((hash >> 11) & 0xFF), UInt8((hash >> 19) & 0xFF))
  }

  private static func encode(_ image: CGImage, as type: UTType) -> Data {
    let buffer = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        buffer, type.identifier as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return buffer as Data
  }

  private static func jpegImage(width: Int, height: Int) -> Data {
    guard let image = detailed(width: width, height: height) else { return Data() }
    return encode(image, as: .jpeg)
  }

  private static func pngImage(width: Int, height: Int) -> Data {
    guard let image = detailed(width: width, height: height) else { return Data() }
    return encode(image, as: .png)
  }
}

// MARK: - Writing PDF syntax

/// The smallest PDF writer that can express the fixture: reserve object numbers up front so
/// dictionaries can refer forwards, fill them in in any order, then emit body and xref.
private final class Builder {
  private var bodies: [Int: Data] = [:]
  private var next = 1

  func reserve() -> Int {
    defer { next += 1 }
    return next
  }

  func define(_ number: Int, _ body: String) {
    bodies[number] = Data(body.utf8)
  }

  func stream(_ number: Int, dictionary: String, data: Data) {
    var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
    body.append(data)
    body.append(Data("\nendstream".utf8))
    bodies[number] = body
  }

  /// The same, with the data deflated — the encoding almost every real PDF uses.
  func flateStream(_ number: Int, dictionary: String, data: Data) {
    guard let deflated = Flate.compress(data) else {
      return stream(number, dictionary: dictionary, data: data)
    }
    stream(number, dictionary: dictionary + " /Filter /FlateDecode", data: deflated)
  }

  func serialize(catalog: Int) -> Data {
    var output = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
    var offsets: [Int: Int] = [:]
    for number in 1..<next {
      guard let body = bodies[number] else { continue }
      offsets[number] = output.count
      output.append(Data("\(number) 0 obj\n".utf8))
      output.append(body)
      output.append(Data("\nendobj\n".utf8))
    }
    let start = output.count
    output.append(Data("xref\n0 \(next)\n0000000000 65535 f \n".utf8))
    for number in 1..<next {
      let offset = offsets[number] ?? 0
      let mark = offsets[number] == nil ? "f" : "n"
      output.append(Data(String(format: "%010d 00000 %@ \n", offset, mark).utf8))
    }
    output.append(
      Data("trailer\n<< /Size \(next) /Root \(catalog) 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
    return output
  }
}

/// zlib-wrapped DEFLATE. `Compression` produces the raw stream, so the two-byte header and the
/// Adler-32 trailer that `/FlateDecode` expects are added here.
private enum Flate {
  static func compress(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    let capacity = data.count + data.count / 2 + 128
    var destination = [UInt8](repeating: 0, count: capacity)
    let written = data.withUnsafeBytes { source -> Int in
      guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return compression_encode_buffer(
        &destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
    }
    guard written > 0 else { return nil }
    var output = Data([0x78, 0x9C])
    output.append(contentsOf: destination[0..<written])
    var checksum = adler32(data).bigEndian
    withUnsafeBytes(of: &checksum) { output.append(contentsOf: $0) }
    return output
  }

  private static func adler32(_ data: Data) -> UInt32 {
    var low: UInt32 = 1
    var high: UInt32 = 0
    for byte in data {
      low = (low + UInt32(byte)) % 65521
      high = (high + low) % 65521
    }
    return (high << 16) | low
  }
}
