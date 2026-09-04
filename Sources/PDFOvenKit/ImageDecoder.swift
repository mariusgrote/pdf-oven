import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the extractor needs to decode one image XObject.
struct ImageFacts {
  var width: Int
  var height: Int
  var bitsPerComponent: Int
  var isMask: Bool
  var hasSoftMask: Bool
}

/// A decoded image, ready to be written to disk.
struct DecodedImage {
  var data: Data
  var fileExtension: String
}

/// The outcome of the decode ladder for one image.
enum DecodeOutcome {
  case decoded(DecodedImage)
  /// Nothing in the ladder could read the pixels; the caller may still rasterize the page.
  case unreadable
}

/// Turns an image XObject into file bytes, trying in order: pass the stored bytes through
/// untouched, rebuild a `CGImage` from the stream dictionary, or give up and say why. The
/// third rung — rasterizing the page region — needs the page, so it lives in `ImageExtractor`.
enum ImageDecoder {
  /// Looks up a colour space that the stream names rather than spells out.
  typealias ColorSpaceResolver = (String) -> PDFObject?

  // MARK: - Facts

  static func facts(of stream: PDFObject) -> ImageFacts? {
    guard let width = (stream["Width"] ?? stream["W"])?.integer,
      let height = (stream["Height"] ?? stream["H"])?.integer,
      width > 0, height > 0
    else { return nil }
    let isMask = (stream["ImageMask"] ?? stream["IM"])?.boolean ?? false
    let bits = (stream["BitsPerComponent"] ?? stream["BPC"])?.integer ?? (isMask ? 1 : 8)
    return ImageFacts(
      width: width,
      height: height,
      bitsPerComponent: isMask ? 1 : bits,
      isMask: isMask,
      hasSoftMask: stream["SMask"]?.stream != nil || stream["Mask"]?.stream != nil
    )
  }

  // MARK: - The ladder

  static func decode(
    _ stream: PDFObject,
    facts: ImageFacts,
    resolver: ColorSpaceResolver,
    preferOriginalEncoding: Bool
  ) -> DecodeOutcome {
    guard stream.stream != nil else { return .unreadable }
    guard let (data, format) = streamData(stream) else { return .unreadable }

    // Rung 1: the document already holds a real image file. Write those bytes verbatim —
    // original resolution, original chroma subsampling, no re-encode.
    let alpha: CGImage?
    if preferOriginalEncoding || !facts.hasSoftMask {
      alpha = nil
    } else {
      guard let decodedAlpha = alphaChannel(of: stream, resolver: resolver) else {
        return .unreadable
      }
      alpha = decodedAlpha
    }
    if preferOriginalEncoding || !facts.hasSoftMask {
      switch format {
      case .jpegEncoded:
        return .decoded(DecodedImage(data: data, fileExtension: "jpg"))
      case .JPEG2000:
        return .decoded(DecodedImage(data: data, fileExtension: "jp2"))
      default: break
      }
    }

    // Rung 2: rebuild the pixels ourselves and write a PNG.
    guard var image = pixels(data, format: format, stream: stream, facts: facts, resolver: resolver)
    else { return .unreadable }
    if let alpha {
      guard let combined = applying(alpha: alpha, to: image) else {
        return .unreadable
      }
      image = combined
    }
    guard let png = png(from: image) else { return .unreadable }
    return .decoded(DecodedImage(data: png, fileExtension: "png"))
  }

  /// Wraps a rasterized fallback the same way, so callers hand one type onwards.
  static func encodePNG(_ image: CGImage) -> DecodedImage? {
    png(from: image).map { DecodedImage(data: $0, fileExtension: "png") }
  }

  // MARK: - Rung 2: reconstruction

  private static func pixels(
    _ data: Data,
    format: CGPDFDataFormat,
    stream: PDFObject,
    facts: ImageFacts,
    resolver: ColorSpaceResolver
  ) -> CGImage? {
    // A JPEG or JPEG 2000 payload only reaches here when it needs an alpha channel bolted on;
    // ImageIO decodes both, so hand it the bytes rather than parse them ourselves.
    if format != .raw {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    if facts.isMask {
      // A 1-bit stencil. Emit it as opaque black where the mask paints, transparent elsewhere.
      guard let alpha = stencilAlpha(data, facts: facts, decode: decodeArray(of: stream)) else {
        return nil
      }
      return grayImage(gray: [UInt8](repeating: 0, count: alpha.count), alpha: alpha, facts: facts)
    }
    guard let space = colorSpace(of: stream, facts: facts, resolver: resolver) else { return nil }

    switch space {
    case .indexed(let baseComponents, let palette, let highest):
      return indexedImage(
        data, facts: facts, baseComponents: baseComponents, palette: palette, highest: highest)
    case .direct(let cgSpace, let components):
      let bytesPerRow = (facts.width * components * facts.bitsPerComponent + 7) / 8
      guard data.count >= bytesPerRow * facts.height,
        let provider = CGDataProvider(data: data as CFData)
      else { return nil }
      let order: CGBitmapInfo = facts.bitsPerComponent == 16 ? .byteOrder16Big : .byteOrderDefault
      return CGImage(
        width: facts.width,
        height: facts.height,
        bitsPerComponent: facts.bitsPerComponent,
        bitsPerPixel: facts.bitsPerComponent * components,
        bytesPerRow: bytesPerRow,
        space: cgSpace,
        bitmapInfo: CGBitmapInfo(rawValue: order.rawValue | CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: decodeArray(of: stream),
        shouldInterpolate: false,
        intent: .defaultIntent)
    }
  }

  private enum ResolvedSpace {
    case direct(CGColorSpace, components: Int)
    /// `/Indexed` is expanded to 8-bit RGB by hand — easier to debug than a palette space,
    /// and it sidesteps the base space entirely.
    case indexed(baseComponents: Int, palette: Data, highest: Int)
  }

  private static func colorSpace(
    of stream: PDFObject, facts: ImageFacts, resolver: ColorSpaceResolver
  ) -> ResolvedSpace? {
    guard var space = stream["ColorSpace"] ?? stream["CS"] else { return nil }
    // A bare name may be shorthand for an entry in the page's /ColorSpace resources.
    if let name = space.name, deviceSpace(named: name) == nil, let resolved = resolver(name) {
      space = resolved
    }
    if let name = space.name { return deviceSpace(named: name) }

    guard let array = space.array, let family = array.first?.name else { return nil }
    switch family {
    case "ICCBased":
      let profile = array.count > 1 ? array[1] : nil
      let components = profile?["N"]?.integer ?? 3
      if let profile, let (data, _) = streamData(profile),
        let iccSpace = CGColorSpace(iccData: data as CFData)
      {
        return .direct(iccSpace, components: components)
      }
      // A broken or unreadable profile still tells us how many components the pixels have.
      return deviceSpace(components: components)
    case "Indexed", "I":
      guard array.count >= 4, let highest = array[2].integer,
        let base = baseComponents(of: array[1], resolver: resolver),
        let palette = paletteBytes(array[3])
      else { return nil }
      return .indexed(baseComponents: base, palette: palette, highest: highest)
    case "CalRGB": return deviceSpace(components: 3)
    case "CalGray": return deviceSpace(components: 1)
    case "Lab":
      return .direct(
        CGColorSpace(name: CGColorSpace.genericLab) ?? CGColorSpaceCreateDeviceRGB(), components: 3)
    case "DeviceGray", "DeviceRGB", "DeviceCMYK": return deviceSpace(named: family)
    // Separation, DeviceN and Pattern need the tint transform run per pixel. Fall through to
    // the rasterizer rather than guess at the colours.
    default: return nil
    }
  }

  private static func deviceSpace(named name: String) -> ResolvedSpace? {
    switch name {
    case "DeviceGray", "G", "CalGray": return .direct(CGColorSpaceCreateDeviceGray(), components: 1)
    case "DeviceRGB", "RGB", "CalRGB": return .direct(CGColorSpaceCreateDeviceRGB(), components: 3)
    case "DeviceCMYK", "CMYK": return .direct(CGColorSpaceCreateDeviceCMYK(), components: 4)
    default: return nil
    }
  }

  private static func deviceSpace(components: Int) -> ResolvedSpace? {
    switch components {
    case 1: return deviceSpace(named: "DeviceGray")
    case 3: return deviceSpace(named: "DeviceRGB")
    case 4: return deviceSpace(named: "DeviceCMYK")
    default: return nil
    }
  }

  private static func baseComponents(of space: PDFObject, resolver: ColorSpaceResolver) -> Int? {
    var space = space
    if let name = space.name, deviceSpace(named: name) == nil, let resolved = resolver(name) {
      space = resolved
    }
    if let name = space.name {
      switch deviceSpace(named: name) {
      case .direct(_, let components): return components
      default: return nil
      }
    }
    guard let array = space.array, let family = array.first?.name else { return nil }
    switch family {
    case "ICCBased": return array.count > 1 ? (array[1]["N"]?.integer ?? 3) : 3
    case "CalRGB", "Lab": return 3
    case "CalGray": return 1
    default: return nil
    }
  }

  private static func paletteBytes(_ lookup: PDFObject) -> Data? {
    if let bytes = lookup.stringBytes { return bytes }
    return streamData(lookup)?.0
  }

  private static func decodeArray(of stream: PDFObject) -> [CGFloat]? {
    let entry = stream["Decode"] ?? stream["D"]
    guard let values = entry?.array?.compactMap(\.real), !values.isEmpty else { return nil }
    return values
  }

  // MARK: - Pixel assembly

  /// Expands an `/Indexed` image to 8-bit RGB, converting palette entries from whatever the
  /// base space stores them in.
  private static func indexedImage(
    _ data: Data, facts: ImageFacts, baseComponents: Int, palette: Data, highest: Int
  ) -> CGImage? {
    let bytesPerRow = (facts.width * facts.bitsPerComponent + 7) / 8
    guard data.count >= bytesPerRow * facts.height else { return nil }
    var rgb = [UInt8](repeating: 0, count: facts.width * facts.height * 3)
    data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
      for y in 0..<facts.height {
        let row = y * bytesPerRow
        for x in 0..<facts.width {
          let index = min(sample(source, row: row, at: x, bits: facts.bitsPerComponent), highest)
          let entry = index * baseComponents
          let target = (y * facts.width + x) * 3
          let colour = paletteColour(palette, at: entry, components: baseComponents)
          rgb[target] = colour.0
          rgb[target + 1] = colour.1
          rgb[target + 2] = colour.2
        }
      }
    }
    guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
    return CGImage(
      width: facts.width, height: facts.height, bitsPerComponent: 8, bitsPerPixel: 24,
      bytesPerRow: facts.width * 3, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  private static func paletteColour(_ palette: Data, at offset: Int, components: Int)
    -> (UInt8, UInt8, UInt8)
  {
    func byte(_ index: Int) -> UInt8 {
      let position = offset + index
      return position < palette.count ? palette[palette.startIndex + position] : 0
    }
    switch components {
    case 1: return (byte(0), byte(0), byte(0))
    case 3: return (byte(0), byte(1), byte(2))
    case 4:
      let key = Int(byte(3))
      let channel = { (value: UInt8) in UInt8(max(0, 255 - Int(value) - key)) }
      return (channel(byte(0)), channel(byte(1)), channel(byte(2)))
    default: return (0, 0, 0)
    }
  }

  /// 255 where a stencil mask paints, 0 where it does not. `/Decode [1 0]` flips the sense.
  private static func stencilAlpha(_ data: Data, facts: ImageFacts, decode: [CGFloat]?) -> [UInt8]?
  {
    let bytesPerRow = (facts.width + 7) / 8
    guard data.count >= bytesPerRow * facts.height else { return nil }
    let inverted = (decode?.first ?? 0) == 1
    var alpha = [UInt8](repeating: 0, count: facts.width * facts.height)
    data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
      for y in 0..<facts.height {
        let row = y * bytesPerRow
        for x in 0..<facts.width {
          let bit = sample(source, row: row, at: x, bits: 1)
          let paints = inverted ? bit == 1 : bit == 0
          alpha[y * facts.width + x] = paints ? 255 : 0
        }
      }
    }
    return alpha
  }

  private static func grayImage(gray: [UInt8], alpha: [UInt8], facts: ImageFacts) -> CGImage? {
    var interleaved = [UInt8](repeating: 0, count: gray.count * 2)
    for index in 0..<gray.count {
      interleaved[index * 2] = gray[index]
      interleaved[index * 2 + 1] = alpha[index]
    }
    guard let provider = CGDataProvider(data: Data(interleaved) as CFData) else { return nil }
    return CGImage(
      width: facts.width, height: facts.height, bitsPerComponent: 8, bitsPerPixel: 16,
      bytesPerRow: facts.width * 2, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// Reads one `bits`-wide sample from a packed row.
  private static func sample(
    _ buffer: UnsafeRawBufferPointer, row: Int, at x: Int, bits: Int
  ) -> Int {
    switch bits {
    case 8: return Int(buffer[row + x])
    case 16: return Int(buffer[row + x * 2])
    default:
      let perByte = 8 / bits
      let byte = Int(buffer[row + x / perByte])
      let shift = 8 - bits * (x % perByte + 1)
      return (byte >> shift) & ((1 << bits) - 1)
    }
  }

  // MARK: - Transparency

  /// The alpha channel a stream carries in `/SMask` or a stencil `/Mask`, as 0…255 coverage.
  private static func alphaChannel(of stream: PDFObject, resolver: ColorSpaceResolver)
    -> CGImage?
  {
    if let soft = stream["SMask"], let facts = facts(of: soft),
      let (data, format) = streamData(soft)
    {
      return pixels(data, format: format, stream: soft, facts: facts, resolver: resolver)
    }
    if let hard = stream["Mask"], let facts = facts(of: hard), let (data, _) = streamData(hard),
      let alpha = stencilAlpha(data, facts: facts, decode: decodeArray(of: hard))
    {
      // A stencil `/Mask` marks the pixels to *drop*, so the painted samples are the
      // transparent ones — the inverse of how `stencilAlpha` reports them.
      return grayImage(
        gray: alpha.map { 255 - $0 }, alpha: [UInt8](repeating: 255, count: alpha.count),
        facts: facts)
    }
    return nil
  }

  /// The stream's bytes with Flate/LZW/RunLength already undone, plus what CoreGraphics left
  /// behind: `.raw` pixel data, or a JPEG / JPEG 2000 payload it did not touch.
  static func streamData(_ object: PDFObject) -> (Data, CGPDFDataFormat)? {
    guard let handle = object.stream else { return nil }
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(handle, &format) else { return nil }
    return (data as Data, format)
  }

  /// Paints `image` opaquely, then replaces its alpha with the luminance of `alpha`, resampling
  /// the mask if the two differ in size (PDF allows that, and scans routinely use it).
  private static func applying(alpha: CGImage, to image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var coverage = [UInt8](repeating: 255, count: width * height)

    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(image, in: rect)
      return true
    }
    guard drawn else { return nil }

    coverage.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return }
      context.draw(alpha, in: rect)
    }

    for index in 0..<(width * height) { pixels[index * 4 + 3] = coverage[index] }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    // Straight (unpremultiplied) alpha: the RGB above was drawn over an opaque buffer.
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  // MARK: - Output

  private static func png(from image: CGImage) -> Data? {
    // PNG carries grey and RGB only, so CMYK and Lab images are converted on the way out.
    let model = image.colorSpace?.model
    let image = (model == .rgb || model == .monochrome) ? image : convertedToRGB(image)
    guard let image else { return nil }
    let buffer = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        buffer, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return buffer as Data
  }

  private static func convertedToRGB(_ image: CGImage) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }
}
