// Generates Packaging/AppIcon.icns for PDF Oven.
// Run: swift Tools/make-icon.swift   (then build.sh picks the .icns up)
//
// The mark is the front of an oven: a graphite squircle body, a metal handle,
// and a glowing door window with a PDF page baking inside it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let rgb = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: rgb,
    components: [
      CGFloat((hex >> 16) & 0xFF) / 255,
      CGFloat((hex >> 8) & 0xFF) / 255,
      CGFloat(hex & 0xFF) / 255,
      alpha,
    ])!
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
  CGGradient(
    colorsSpace: rgb,
    colors: stops.map { color($0.0, $0.1) } as CFArray,
    locations: stops.map { $0.2 })!
}

/// Superellipse, the shape macOS app icons use.
func squircle(center: CGPoint, radius r: CGFloat, n: CGFloat = 5) -> CGPath {
  let path = CGMutablePath()
  let steps = 720
  for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let c = cos(t)
    let s = sin(t)
    let x = center.x + r * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
    let y = center.y + r * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
  }
  path.closeSubpath()
  return path
}

/// A page: rounded rect with the top-right corner folded away.
func pagePath(_ rect: CGRect, fold f: CGFloat, radius r: CGFloat) -> CGPath {
  let p = CGMutablePath()
  let (l, t, rt, b) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
  p.move(to: CGPoint(x: l, y: t + r))
  p.addQuadCurve(to: CGPoint(x: l + r, y: t), control: CGPoint(x: l, y: t))
  p.addLine(to: CGPoint(x: rt - f, y: t))  // up to the fold
  p.addLine(to: CGPoint(x: rt, y: t + f))  // diagonal cut
  p.addLine(to: CGPoint(x: rt, y: b - r))
  p.addQuadCurve(to: CGPoint(x: rt - r, y: b), control: CGPoint(x: rt, y: b))
  p.addLine(to: CGPoint(x: l + r, y: b))
  p.addQuadCurve(to: CGPoint(x: l, y: b - r), control: CGPoint(x: l, y: b))
  p.closeSubpath()
  return p
}

func draw(into ctx: CGContext) {
  // Top-left origin, so layout numbers read like a design canvas.
  ctx.translateBy(x: 0, y: canvas)
  ctx.scaleBy(x: 1, y: -1)

  let body = squircle(center: CGPoint(x: 512, y: 500), radius: 412)
  let bodyBox = body.boundingBox

  // Contact shadow under the icon body.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 34, color: color(0x000000, 0.30))
  ctx.addPath(body)
  ctx.setFillColor(color(0x2B2E35))
  ctx.fillPath()
  ctx.restoreGState()

  // Oven body: brushed graphite.
  ctx.saveGState()
  ctx.addPath(body)
  ctx.clip()
  ctx.drawLinearGradient(
    gradient([(0x5A5F6B, 1, 0), (0x3C4049, 1, 0.55), (0x1E2126, 1, 1)]),
    start: CGPoint(x: 0, y: bodyBox.minY),
    end: CGPoint(x: 0, y: bodyBox.maxY),
    options: [])

  // Heat pooling at the bottom of the body.
  ctx.drawRadialGradient(
    gradient([(0xFF7A18, 0.30, 0), (0xFF7A18, 0, 1)]),
    startCenter: CGPoint(x: 512, y: 880), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 880), endRadius: 430,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  ctx.restoreGState()

  // Glass rim along the top edge.
  ctx.saveGState()
  ctx.addPath(body)
  ctx.clip()
  ctx.addPath(body)
  ctx.setStrokeColor(color(0xFFFFFF, 0.22))
  ctx.setLineWidth(10)
  ctx.strokePath()
  ctx.restoreGState()

  // Handle.
  let handle = CGRect(x: 190, y: 168, width: 644, height: 54)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 16, color: color(0x000000, 0.45))
  ctx.addPath(CGPath(roundedRect: handle, cornerWidth: 27, cornerHeight: 27, transform: nil))
  ctx.setFillColor(color(0xC8CDD6))
  ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(CGPath(roundedRect: handle, cornerWidth: 27, cornerHeight: 27, transform: nil))
  ctx.clip()
  ctx.drawLinearGradient(
    gradient([(0xF2F5FA, 1, 0), (0xC2C8D2, 1, 0.5), (0x878E9A, 1, 1)]),
    start: CGPoint(x: 0, y: handle.minY),
    end: CGPoint(x: 0, y: handle.maxY),
    options: [])
  ctx.restoreGState()

  // Door window.
  let window = CGRect(x: 190, y: 300, width: 644, height: 530)
  let windowPath = CGPath(roundedRect: window, cornerWidth: 96, cornerHeight: 96, transform: nil)

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 46, color: color(0xFF6A12, 0.55))
  ctx.addPath(windowPath)
  ctx.setFillColor(color(0xD8420C))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(windowPath)
  ctx.clip()
  ctx.drawRadialGradient(
    gradient([(0xFFC96E, 1, 0), (0xFF8A28, 1, 0.5), (0xE24A0C, 1, 0.82), (0xB22F08, 1, 1)]),
    startCenter: CGPoint(x: 512, y: 620), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 620), endRadius: 440,
    options: [.drawsAfterEndLocation])
  // Vignette, so the glass darkens toward its frame instead of ending on a hard line.
  ctx.drawRadialGradient(
    gradient([(0x2A0C00, 0, 0), (0x2A0C00, 0, 0.62), (0x2A0C00, 0.45, 1)]),
    startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 600), endRadius: 400,
    options: [.drawsAfterEndLocation])
  // Glass sheen across the upper half.
  ctx.drawLinearGradient(
    gradient([(0xFFFFFF, 0.32, 0), (0xFFFFFF, 0.05, 0.45), (0xFFFFFF, 0, 0.6)]),
    start: CGPoint(x: 0, y: window.minY),
    end: CGPoint(x: 0, y: window.maxY),
    options: [])
  ctx.restoreGState()

  // Window bezel: a warm-dark frame with a lit top edge.
  ctx.saveGState()
  ctx.addPath(windowPath)
  ctx.setStrokeColor(color(0x1A1512, 0.75))
  ctx.setLineWidth(11)
  ctx.strokePath()
  ctx.restoreGState()

  // The page, baking.
  let pageRect = CGRect(x: 367, y: 385, width: 290, height: 360)
  let page = pagePath(pageRect, fold: 76, radius: 16)

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x5A1A00, 0.45))
  ctx.addPath(page)
  ctx.setFillColor(color(0xFFFFFF))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(page)
  ctx.clip()
  ctx.drawLinearGradient(
    gradient([(0xFFFFFF, 1, 0), (0xFFF4E6, 1, 1)]),
    start: CGPoint(x: 0, y: pageRect.minY),
    end: CGPoint(x: 0, y: pageRect.maxY),
    options: [])
  ctx.restoreGState()

  // Folded corner.
  let fold = CGMutablePath()
  fold.move(to: CGPoint(x: pageRect.maxX - 76, y: pageRect.minY))
  fold.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.minY + 76))
  fold.addLine(to: CGPoint(x: pageRect.maxX - 76, y: pageRect.minY + 76))
  fold.closeSubpath()
  ctx.addPath(fold)
  ctx.setFillColor(color(0xEFD3B4))
  ctx.fillPath()

  // Content lines.
  func line(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    ctx.addPath(
      CGPath(
        roundedRect: CGRect(x: x, y: y, width: w, height: h),
        cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setFillColor(color(hex, a))
    ctx.fillPath()
  }
  line(407, 428, 148, 26, 0x8A3410, 0.90)
  for (i, w) in [CGFloat(210), 210, 186, 132].enumerated() {
    line(407, 496 + CGFloat(i) * 44, w, 16, 0xC4551F, 0.75)
  }
}

func render(size: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: 0, space: rgb,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setAllowsAntialiasing(true)
  ctx.interpolationQuality = .high
  let scale = CGFloat(size) / canvas
  ctx.scaleBy(x: scale, y: scale)
  draw(into: ctx)
  return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
  let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
  write(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  write(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
write(render(size: 1024), to: root.appendingPathComponent("build/AppIcon-preview.png"))

let icns = root.appendingPathComponent("Packaging/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(icns.path)")
