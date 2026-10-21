// Draws the app icon: a complete silver disc on blue, with a Liquid Glass ring over its lower
// right edge holding a blue puck with two-way arrows (Mac ⇄ Windows). The clear glass ring bends
// the disc's rim and tracks underneath, like the ring in the macOS 26 Maps icon.
//
//   swift scripts/make_icon.swift layers <dir>   disc.png, ring.png, puck.png, arrows.png for the
//                                                layered Icon Composer icon (Resources/AppIcon.icon);
//                                                macOS draws the shape, glass, refraction and shadows
//   swift scripts/make_icon.swift flat <out.png> the same picture flattened, with its own rounded
//                                                body and a painted ring, for systems without Xcode
import AppKit

let args = CommandLine.arguments
guard args.count == 3, ["flat", "layers"].contains(args[1]) else {
    print("usage: make_icon.swift layers <dir> | flat <out.png>"); exit(1)
}

// Layout on the 1024 canvas (the whole canvas is the icon; macOS masks it to the icon shape).
let discCenter = CGPoint(x: 470, y: 560), discRadius: CGFloat = 340
let lensCenter = CGPoint(x: 690, y: 360)
let ringOuter: CGFloat = 196, ringInner: CGFloat = 132   // the puck fills the inside of the ring

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map { rgb($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

final class Canvas {
    let rep: NSBitmapImageRep
    let g: CGContext
    init() {
        rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        g = ctx.cgContext
    }
    func save(_ path: String) {
        NSGraphicsContext.current = nil
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// Angular gradient from thin wedges (Core Graphics has no conic gradient here).
func conic(_ g: CGContext, _ colors: [UInt32], center: CGPoint, radius: CGFloat, startAngle: CGFloat) {
    let steps = 720
    func comp(_ c: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((c >> shift) & 0xFF) / 255 }
    g.saveGState()
    g.setShouldAntialias(false)   // no hairline seams between wedges
    for i in 0 ..< steps {
        let t = CGFloat(i) / CGFloat(steps) * CGFloat(colors.count - 1)
        let a = colors[Int(t)], b = colors[min(Int(t) + 1, colors.count - 1)], f = t - CGFloat(Int(t))
        let mix = { (s: UInt32) in comp(a, s) * (1 - f) + comp(b, s) * f }
        let a0 = startAngle + CGFloat(i) / CGFloat(steps) * 2 * .pi
        g.move(to: center)
        g.addArc(center: center, radius: radius, startAngle: a0, endAngle: a0 + 2 * .pi / CGFloat(steps) + 0.003, clockwise: false)
        g.closePath()
        g.setFillColor(CGColor(srgbRed: mix(16), green: mix(8), blue: mix(0), alpha: 1))
        g.fillPath()
    }
    g.restoreGState()
}

// MARK: Layers

/// A complete, recognisable disc: silver, a soft rainbow sheen, tracks, a clear hub, the hole.
func drawDisc(_ g: CGContext) {
    let c = discCenter, R = discRadius
    let hole = R * 0.13, hub = R * 0.34
    let path = CGMutablePath()
    path.addEllipse(in: circle(c, R))
    path.addEllipse(in: circle(c, hole))
    g.saveGState()
    g.addPath(path); g.clip(using: .evenOdd)
    g.drawRadialGradient(gradient([(0xFFFFFF, 1, 0), (0xEDF1F7, 1, 0.5), (0xC3CCDA, 1, 1)]),
                         startCenter: c, startRadius: 0, endCenter: c, endRadius: R, options: [])
    g.saveGState()
    g.setAlpha(0.55)
    conic(g, [0xFF8AC0, 0xFFD36E, 0x8CF5C4, 0x6FD3FF, 0xA98BFF, 0xFF8AC0, 0xFFE08A, 0x7FE3FF, 0xFF8AC0],
          center: c, radius: R, startAngle: .pi / 5)
    g.restoreGState()
    for f in [0.94, 0.82, 0.70, 0.58, 0.46] as [CGFloat] {
        g.addEllipse(in: circle(c, R * f)); g.setStrokeColor(rgb(0xFFFFFF, 0.5)); g.setLineWidth(3); g.strokePath()
    }
    g.addEllipse(in: circle(c, hub)); g.setFillColor(rgb(0xF6F8FB, 0.92)); g.fillPath()
    g.addEllipse(in: circle(c, hub)); g.setStrokeColor(rgb(0xA7B2C4, 0.8)); g.setLineWidth(4); g.strokePath()
    g.addEllipse(in: circle(c, hole + R * 0.07)); g.setStrokeColor(rgb(0xB9C3D2)); g.setLineWidth(3); g.strokePath()
    let hl = CGPoint(x: c.x - R * 0.42, y: c.y + R * 0.5)
    g.drawRadialGradient(gradient([(0xFFFFFF, 0.85, 0), (0xFFFFFF, 0, 1)]),
                         startCenter: hl, startRadius: 0, endCenter: hl, endRadius: R * 0.6, options: [])
    g.restoreGState()
    g.addEllipse(in: circle(c, R - 3)); g.setStrokeColor(rgb(0xFFFFFF)); g.setLineWidth(6); g.strokePath()
    g.addEllipse(in: circle(c, hole + 2)); g.setStrokeColor(rgb(0x8C98AD)); g.setLineWidth(4); g.strokePath()
}

/// The glass ring: a plain white ring. macOS renders it as clear Liquid Glass that refracts the disc.
func drawRing(_ g: CGContext) {
    let path = CGMutablePath()
    path.addEllipse(in: circle(lensCenter, ringOuter))
    path.addEllipse(in: circle(lensCenter, ringInner))
    g.addPath(path); g.setFillColor(rgb(0xFFFFFF)); g.fillPath(using: .evenOdd)
}

func drawPuck(_ g: CGContext) {
    g.saveGState()
    g.addEllipse(in: circle(lensCenter, ringInner)); g.clip()
    g.drawLinearGradient(gradient([(0x3D9BFF, 1, 0), (0x0A6CFF, 1, 1)]),
                         start: CGPoint(x: lensCenter.x, y: lensCenter.y + ringInner),
                         end: CGPoint(x: lensCenter.x, y: lensCenter.y - ringInner), options: [])
    g.restoreGState()
}

func drawArrows() {
    let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .heavy)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let arrows = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let s = arrows.size, k = 150 / max(s.width, s.height)
    arrows.draw(in: CGRect(x: lensCenter.x - s.width * k / 2, y: lensCenter.y - s.height * k / 2,
                           width: s.width * k, height: s.height * k))
}

// MARK: Output

if args[1] == "layers" {
    let dir = args[2]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var c = Canvas(); drawDisc(c.g); c.save(dir + "/disc.png")
    c = Canvas(); drawRing(c.g); c.save(dir + "/ring.png")
    c = Canvas(); drawPuck(c.g); c.save(dir + "/puck.png")
    c = Canvas(); drawArrows(); c.save(dir + "/arrows.png")
} else {
    // Flat version: everything inside a rounded body on the 824-point macOS grid, with drop
    // shadows and the glass ring imitated by a translucent white fill and a bright edge.
    let c = Canvas()
    let g = c.g
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.3))
    g.addPath(shape); g.setFillColor(rgb(0x1E4FD8)); g.fillPath()
    g.restoreGState()
    g.saveGState()
    g.addPath(shape); g.clip()
    g.drawLinearGradient(gradient([(0x3B82F6, 1, 0), (0x1D4ED8, 1, 1)]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    g.translateBy(x: 100, y: 100); g.scaleBy(x: 824 / 1024, y: 824 / 1024)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: rgb(0x0B1E5B, 0.45))
    let shadowShape = CGMutablePath()
    shadowShape.addEllipse(in: circle(discCenter, discRadius))
    shadowShape.addEllipse(in: circle(discCenter, discRadius * 0.13))   // keep the hole open
    g.addPath(shadowShape); g.setFillColor(rgb(0xE9EDF5)); g.fillPath(using: .evenOdd)
    g.restoreGState()
    drawDisc(g)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: rgb(0x0B1E5B, 0.4))
    let ring = CGMutablePath()
    ring.addEllipse(in: circle(lensCenter, ringOuter)); ring.addEllipse(in: circle(lensCenter, ringInner))
    g.addPath(ring); g.setFillColor(rgb(0xFFFFFF, 0.4)); g.fillPath(using: .evenOdd)
    g.restoreGState()
    g.addEllipse(in: circle(lensCenter, ringOuter - 3)); g.setStrokeColor(rgb(0xFFFFFF, 0.9)); g.setLineWidth(6); g.strokePath()
    drawPuck(g)
    drawArrows()
    g.restoreGState()
    c.save(args[2])
}
