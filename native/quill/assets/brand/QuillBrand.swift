#!/usr/bin/env swift
//
// Draws every raster asset of Quill's brand from one geometry: the app icon (and its
// .icns), the mark, the one-ink mark, the share images and the installer background.
// Drawn by code, not committed as binaries that drift: a design change is a readable diff.
//
//   swift QuillBrand.swift icon        <out.png> <pixels>   dark app icon (the default)
//   swift QuillBrand.swift icon-light  <out.png> <pixels>   light appearance
//   swift QuillBrand.swift icon-bleed  <out.png> <pixels>   full-bleed square (apple-touch-icon)
//   swift QuillBrand.swift mark        <out.png> <pixels>   quill + selection, transparent
//   swift QuillBrand.swift mono        <out.png> <pixels>   the mark in one ink (black)
//   swift QuillBrand.swift mono-white  <out.png> <pixels>   the mark in one ink (white)
//   swift QuillBrand.swift og-es|og-en <out.png> <font.ttf> share image, 1200×630
//   swift QuillBrand.swift dmg         <out.png>            installer window, 620×400 at 2×
//   swift QuillBrand.swift icns        <out.icns>           every macOS icon size
//
// The concept (owner's choice, 2026-10-05): a glass quill laid across a text selection —
// the name, and where the app works. In the manner of macOS 27: layers of glass with
// refraction where they overlap, a bright specular rim and a darkened edge.
import AppKit
import CoreGraphics
import CoreText

// MARK: - Palette

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

/// Indigo ink: Quill's own colour — Ámbar is amber on night, Tessera black and white.
enum Palette {
    static let inkTop: UInt32 = 0x2C2F9E
    static let inkMid: UInt32 = 0x1A1660
    static let inkBottom: UInt32 = 0x0B0A2E
    static let glow: UInt32 = 0x7C8CFF
    static let selectionLight: UInt32 = 0x6FA2FF
    static let selection: UInt32 = 0x2F6BFF
    static let handle: UInt32 = 0x3D78FF
    static let rim: UInt32 = 0x14125A
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    rounded(CGRect(x: x, y: y, width: w, height: h), min(w, h) / 2)
}

// MARK: - Geometry (1024-unit canvas, top-left origin)

enum Geometry {
    /// Apple's macOS grid: an 824 body inside 1024.
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let bodyRadius: CGFloat = 185
    static let band = CGRect(x: 196, y: 556, width: 632, height: 132)
    static let bandRadius: CGFloat = 26
    /// (stem x, knob centre y, stem top, stem bottom): top left and bottom right, as on
    /// every text selection.
    static let handles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(196, 520, 520, 700), (828, 724, 544, 724)]
    static let quill = CGAffineTransform(translationX: 506, y: 468).rotated(by: 0.70)
        .scaledBy(x: 0.93, y: 0.93).translatedBy(x: -512, y: -512)

    static var vane: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 512, y: 128))
        path.addCurve(to: CGPoint(x: 612, y: 450), control1: CGPoint(x: 566, y: 200), control2: CGPoint(x: 616, y: 320))
        path.addCurve(to: CGPoint(x: 516, y: 748), control1: CGPoint(x: 608, y: 590), control2: CGPoint(x: 566, y: 690))
        path.addLine(to: CGPoint(x: 508, y: 748))
        path.addCurve(to: CGPoint(x: 412, y: 450), control1: CGPoint(x: 458, y: 690), control2: CGPoint(x: 416, y: 590))
        path.addCurve(to: CGPoint(x: 512, y: 128), control1: CGPoint(x: 408, y: 320), control2: CGPoint(x: 458, y: 200))
        path.closeSubpath()
        var t = quill
        return path.copy(using: &t)!
    }

    /// Thin wedges cut from the vane's edge, angled like the barbs: what makes it a feather.
    static var notches: CGPath {
        let path = CGMutablePath()
        for (x, y, inward) in [(606.0, 400.0, -0.62), (420.0, 560.0, 0.62)] {
            path.move(to: CGPoint(x: x, y: y - 6))
            path.addLine(to: CGPoint(x: x + inward * 74, y: y + 20))
            path.addLine(to: CGPoint(x: x, y: y + 16))
            path.closeSubpath()
        }
        var t = quill
        return path.copy(using: &t)!
    }

    /// The shaft runs past the vane into a sharp writing point: the quill writes.
    static var shaft: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 511, y: 170)); path.addLine(to: CGPoint(x: 513, y: 170))
        path.addLine(to: CGPoint(x: 524, y: 760)); path.addLine(to: CGPoint(x: 512, y: 880))
        path.addLine(to: CGPoint(x: 500, y: 760)); path.closeSubpath()
        var t = quill
        return path.copy(using: &t)!
    }

    static var shaftLine: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 512, y: 200)); path.addLine(to: CGPoint(x: 512, y: 760))
        var t = quill
        return path.copy(using: &t)!
    }

    static var barbs: CGPath {
        let path = CGMutablePath()
        for i in 0..<9 {
            let y = 250 + CGFloat(i) * 52
            path.move(to: CGPoint(x: 512, y: y + 40)); path.addLine(to: CGPoint(x: 640, y: y - 30))
            path.move(to: CGPoint(x: 512, y: y + 40)); path.addLine(to: CGPoint(x: 400, y: y - 20))
        }
        var t = quill
        return path.copy(using: &t)!
    }
}

// MARK: - Canvas

/// A square bitmap whose drawing space is the 1024-unit, top-left canvas.
func canvas(pixels: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels)); context.scaleBy(x: scale, y: -scale)
    context.setShouldAntialias(true); context.interpolationQuality = .high
    draw(context)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: - The layers

struct Style {
    var light = false
    /// Over a dark background the glass is white; over a light one it is tinted indigo.
    var glassColors: [CGColor] {
        light ? [rgba(0x8E9BFF, 0.62), rgba(0x6F7CF2, 0.48), rgba(0x9B7BFF, 0.52)]
              : [rgba(0xFFFFFF, 0.78), rgba(0xD9E4FF, 0.46), rgba(0xC9B6FF, 0.40)]
    }
    var shadowAlpha: CGFloat { light ? 0.28 : 0.55 }
}

func drawBackground(_ ctx: CGContext, light: Bool, in rect: CGRect) {
    if light {
        ctx.drawLinearGradient(gradient([rgba(0xFFFFFF), rgba(0xE9E6FF)]),
                               start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    } else {
        ctx.drawLinearGradient(gradient([rgba(Palette.inkTop), rgba(Palette.inkMid), rgba(Palette.inkBottom)], [0, 0.5, 1]),
                               start: CGPoint(x: rect.minX + 100, y: rect.minY), end: CGPoint(x: rect.maxX - 100, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let glowCentre = CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.19)
        ctx.drawRadialGradient(gradient([rgba(Palette.glow, 0.55), rgba(Palette.glow, 0)]), startCenter: glowCentre, startRadius: 0,
                               endCenter: glowCentre, endRadius: rect.width * 0.68, options: [])
    }
}

func drawSelection(_ ctx: CGContext, style: Style, saturated: Bool = false, bodyOnly: Bool = false) {
    let path = rounded(Geometry.band, Geometry.bandRadius)
    if !bodyOnly {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 34, color: rgba(0x0A0A40, style.light ? 0.22 : 0.5))
        ctx.addPath(path); ctx.setFillColor(rgba(Palette.selection, 0.6)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let alpha: CGFloat = saturated ? 0.95 : 0.78
    ctx.drawLinearGradient(gradient([rgba(Palette.selectionLight, alpha), rgba(Palette.selection, alpha)]),
                           start: CGPoint(x: 0, y: Geometry.band.minY), end: CGPoint(x: 0, y: Geometry.band.maxY), options: [])
    ctx.restoreGState()
    if bodyOnly { return }
    ctx.addPath(path); ctx.setLineWidth(6); ctx.setStrokeColor(rgba(0x0A1A66, 0.45)); ctx.strokePath()
    ctx.saveGState(); ctx.addPath(path); ctx.clip(); ctx.translateBy(x: 0, y: 6)
    ctx.addPath(path); ctx.setLineWidth(8); ctx.setStrokeColor(rgba(0xFFFFFF, 0.75)); ctx.strokePath(); ctx.restoreGState()
    for (x, knob, top, bottom) in Geometry.handles {
        ctx.addPath(pill(x - 7, top, 14, bottom - top)); ctx.setFillColor(rgba(Palette.selection)); ctx.fillPath()
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 14, color: rgba(Palette.selectionLight, 0.8))
        ctx.addEllipse(in: CGRect(x: x - 30, y: knob - 30, width: 60, height: 60)); ctx.setFillColor(rgba(Palette.handle)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addEllipse(in: CGRect(x: x - 13, y: knob - 22, width: 26, height: 14)); ctx.setFillColor(rgba(0xFFFFFF, 0.55)); ctx.fillPath()
    }
}

func drawQuill(_ ctx: CGContext, style: Style) {
    let vane = Geometry.vane
    // The vane's tip is far sharper than the default miter limit (10): without this, every
    // stroke along its edge is bevelled there and the tip reads as cut off.
    ctx.setMiterLimit(60)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: 28), blur: 50, color: rgba(0x070630, style.shadowAlpha))
    ctx.addPath(vane); ctx.setFillColor(rgba(0xFFFFFF, 0.1)); ctx.fillPath(); ctx.restoreGState()

    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState(); ctx.addPath(vane); ctx.clip()
    // Refraction: the selection seen through the glass, shifted and deeper.
    ctx.saveGState(); ctx.translateBy(x: -16, y: -10); drawSelection(ctx, style: style, saturated: true, bodyOnly: true); ctx.restoreGState()
    ctx.drawLinearGradient(gradient(style.glassColors, [0, 0.55, 1]), start: CGPoint(x: 360, y: 200), end: CGPoint(x: 760, y: 760), options: [])
    ctx.addPath(Geometry.barbs); ctx.setLineWidth(5); ctx.setStrokeColor(rgba(0xFFFFFF, 0.28)); ctx.strokePath()
    // Thickness: a soft glow inside the edge.
    ctx.addPath(vane); ctx.setLineWidth(40); ctx.setStrokeColor(rgba(0xFFFFFF, 0.18)); ctx.strokePath()
    ctx.restoreGState()
    ctx.setBlendMode(.clear); ctx.addPath(Geometry.notches); ctx.fillPath(); ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()

    // The darkened edge, then the specular rim on the lit side.
    ctx.addPath(vane); ctx.setLineWidth(6); ctx.setStrokeColor(rgba(Palette.rim, 0.45)); ctx.strokePath()
    ctx.saveGState(); ctx.addPath(vane); ctx.clip(); ctx.translateBy(x: 7, y: 7)
    ctx.addPath(vane); ctx.setLineWidth(10); ctx.setStrokeColor(rgba(0xFFFFFF, 0.9)); ctx.strokePath(); ctx.restoreGState()

    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 10, color: rgba(0xFFFFFF, 0.6))
    ctx.addPath(Geometry.shaft); ctx.setFillColor(style.light ? rgba(0x3B3FC9) : rgba(0xFFFFFF, 0.95)); ctx.fillPath()
    ctx.restoreGState()
}

/// The app icon. `bleed` fills the square (iOS masks its own corners).
func drawIcon(_ ctx: CGContext, light: Bool, bleed: Bool) {
    let style = Style(light: light)
    let shape = bleed ? CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil)
                      : rounded(Geometry.body, Geometry.bodyRadius)
    if !bleed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: rgba(0x000000, 0.35))
        ctx.addPath(shape); ctx.setFillColor(rgba(0x000000)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    drawBackground(ctx, light: light, in: bleed ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : Geometry.body)
    drawSelection(ctx, style: style)
    drawQuill(ctx, style: style)
    ctx.restoreGState()
    if !bleed {
        // A hairline that holds the body on light and dark backgrounds alike.
        ctx.addPath(rounded(Geometry.body.insetBy(dx: 3, dy: 3), Geometry.bodyRadius - 3))
        ctx.setLineWidth(6); ctx.setStrokeColor(rgba(0xFFFFFF, light ? 0.6 : 0.14)); ctx.strokePath()
    }
}

/// The mark without its body: quill and selection, for documents and the web.
func drawMark(_ ctx: CGContext) {
    // Re-centred: without the body, the pair sits in the middle of its own canvas.
    ctx.translateBy(x: 0, y: 6)
    let style = Style(light: true)
    drawSelection(ctx, style: style)
    drawQuill(ctx, style: style)
}

/// The mark in one ink: the selection, knocked out where the quill crosses it, and the
/// quill, its shaft a groove down the vane and ink past it.
func drawMono(_ ctx: CGContext, color: CGColor) {
    ctx.setMiterLimit(60)  // the vane's sharp tip, as in drawQuill
    ctx.translateBy(x: 0, y: 6)
    let all = CGRect(x: -512, y: -512, width: 2048, height: 2048)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color)
    ctx.addPath(rounded(Geometry.band, Geometry.bandRadius)); ctx.fillPath()
    for (x, knob, top, bottom) in Geometry.handles {
        ctx.addPath(pill(x - 7, top, 14, bottom - top)); ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: x - 30, y: knob - 30, width: 60, height: 60)); ctx.fillPath()
    }
    // A gap around the quill, so it reads in front of the selection with one ink.
    ctx.setBlendMode(.clear)
    ctx.addPath(Geometry.vane); ctx.setLineWidth(44); ctx.strokePath()
    ctx.addPath(Geometry.shaft); ctx.setLineWidth(36); ctx.strokePath()
    ctx.setBlendMode(.normal)
    ctx.addPath(Geometry.vane); ctx.fillPath()
    ctx.setBlendMode(.clear)
    ctx.addPath(Geometry.notches); ctx.fillPath()
    ctx.saveGState(); ctx.addPath(Geometry.vane); ctx.clip()
    ctx.addPath(Geometry.shaftLine); ctx.setLineWidth(10); ctx.strokePath()
    ctx.restoreGState()
    ctx.setBlendMode(.normal)
    ctx.saveGState(); ctx.addRect(all); ctx.addPath(Geometry.vane); ctx.clip(using: .evenOdd)
    ctx.addPath(Geometry.shaft); ctx.fillPath()
    ctx.restoreGState()
    ctx.endTransparencyLayer()
}

// MARK: - Share images and installer

func loadFont(_ path: String, size: CGFloat) -> CTFont {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], let first = descriptors.first else {
        fatalError("cannot read the font at \(path)")
    }
    return CTFontCreateWithFontDescriptor(first, size, nil)
}

func drawText(_ ctx: CGContext, _ text: String, font: CTFont, color: CGColor, at point: CGPoint, kern: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                     .init(kCTForegroundColorAttributeName as String): color,
                                                     .kern: kern]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.saveGState()
    // The canvas is top-left; Core Text draws bottom-up from its baseline.
    ctx.textMatrix = .identity
    ctx.translateBy(x: point.x, y: point.y); ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func shareImage(language: String, fontPath: String) -> CGImage {
    let width = 1200, height = 630
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    drawBackground(ctx, light: false, in: CGRect(x: 0, y: 0, width: width, height: height))
    // The icon, left, at 380 px.
    let icon = canvas(pixels: 760) { drawIcon($0, light: false, bleed: false) }
    ctx.saveGState(); ctx.translateBy(x: 70, y: 125 + 380); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(icon, in: CGRect(x: 0, y: 0, width: 380, height: 380)); ctx.restoreGState()
    let name = loadFont(fontPath, size: 150)
    drawText(ctx, "quill", font: name, color: rgba(0xFFFFFF), at: CGPoint(x: 500, y: 330), kern: -150 * 0.045)
    let tagline = loadFont(fontPath, size: 38)
    let line = language == "es" ? "Reescribe lo que seleccionas," : "Rewrite what you select,"
    let second = language == "es" ? "con tu estilo, en cualquier app." : "in your own voice, in any app."
    drawText(ctx, line, font: tagline, color: rgba(0xD9DEFF, 0.92), at: CGPoint(x: 506, y: 410))
    drawText(ctx, second, font: tagline, color: rgba(0xD9DEFF, 0.92), at: CGPoint(x: 506, y: 462))
    return ctx.makeImage()!
}

/// The installer window: 620×400 points, saved at 2×. No words — one DMG serves every
/// language; the arrow says "drag this there" (the rule Ámbar's installer follows).
func installerBackground() -> NSBitmapImageRep {
    let scale: CGFloat = 2, width: CGFloat = 620, height: CGFloat = 400
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // The bitmap's `size` is in points, so the context is already scaled to 2×.
    ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)
    // Pale lavender: the ink of the icon, lowered so both icons on top read clearly.
    ctx.drawLinearGradient(gradient([rgba(0xF7F6FF), rgba(0xE6E3FB)]), start: .zero, end: CGPoint(x: 0, y: height), options: [])
    // The arrow between the icon slots (Quill at x 170, Applications at x 450, y 170).
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 262, y: 170)); arrow.addLine(to: CGPoint(x: 350, y: 170))
    ctx.addPath(arrow); ctx.setLineWidth(6); ctx.setLineCap(.round); ctx.setStrokeColor(rgba(0x3B3FC9, 0.45)); ctx.strokePath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 336, y: 152)); head.addLine(to: CGPoint(x: 362, y: 170)); head.addLine(to: CGPoint(x: 336, y: 188))
    ctx.addPath(head); ctx.setLineJoin(.round); ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - .icns

func writeICNS(to output: String) {
    let set = FileManager.default.temporaryDirectory.appendingPathComponent("Quill-\(UUID().uuidString).iconset")
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        writePNG(canvas(pixels: size) { drawIcon($0, light: false, bleed: false) }, to: set.appendingPathComponent("icon_\(size)x\(size).png").path)
        writePNG(canvas(pixels: size * 2) { drawIcon($0, light: false, bleed: false) }, to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png").path)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", set.path, "-o", output]
    try! process.run(); process.waitUntilExit()
    try? FileManager.default.removeItem(at: set)
    guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
}

// MARK: - Command line

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: QuillBrand.swift <icon|icon-light|icon-bleed|mark|mono|mono-white|og-es|og-en|dmg|icns> <out> [pixels|font]\n".utf8))
    exit(64)
}
let (mode, out) = (args[1], args[2])
let pixels = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
switch mode {
case "icon": writePNG(canvas(pixels: pixels) { drawIcon($0, light: false, bleed: false) }, to: out)
case "icon-light": writePNG(canvas(pixels: pixels) { drawIcon($0, light: true, bleed: false) }, to: out)
case "icon-bleed": writePNG(canvas(pixels: pixels) { drawIcon($0, light: false, bleed: true) }, to: out)
case "mark": writePNG(canvas(pixels: pixels) { drawMark($0) }, to: out)
case "mono": writePNG(canvas(pixels: pixels) { drawMono($0, color: rgba(0x000000)) }, to: out)
case "mono-white": writePNG(canvas(pixels: pixels) { drawMono($0, color: rgba(0xFFFFFF)) }, to: out)
case "og-es", "og-en": writePNG(shareImage(language: String(mode.suffix(2)), fontPath: args[3]), to: out)
case "dmg": try! installerBackground().representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
case "icns": writeICNS(to: out)
default:
    FileHandle.standardError.write(Data("unknown mode \(mode)\n".utf8)); exit(64)
}
