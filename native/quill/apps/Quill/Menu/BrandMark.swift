import AppKit

/// Quill's mark for the menu bar: the quill crossing the selection, in one ink, as a
/// template image so the system tints it for the bar's appearance. The geometry is the
/// brand's (assets/brand/QuillBrand.swift, `drawMono`), simplified for 18 points: the
/// barbs and notches would be noise at this size, the silhouette is what reads.
enum BrandMark {
    static func menuBarImage(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The brand's 1024 canvas, framed on the mark's ink — knob to knob (x 162…862) and
            // quill tip to lower knob (y 150…758) — with a hair of margin, centred.
            let scale: CGFloat = 18 / 724
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -150, y: -92)
            draw(in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static let quill = CGAffineTransform(translationX: 540, y: 478).rotated(by: 0.70)
        .scaledBy(x: 0.93, y: 0.93).translatedBy(x: -512, y: -512)

    private static func draw(in context: CGContext) {
        var transform = quill
        let vane = CGMutablePath()
        vane.move(to: CGPoint(x: 512, y: 150))
        vane.addCurve(to: CGPoint(x: 626, y: 470), control1: CGPoint(x: 590, y: 230), control2: CGPoint(x: 640, y: 350))
        vane.addCurve(to: CGPoint(x: 520, y: 742), control1: CGPoint(x: 612, y: 590), control2: CGPoint(x: 560, y: 690))
        vane.addCurve(to: CGPoint(x: 424, y: 520), control1: CGPoint(x: 470, y: 690), control2: CGPoint(x: 420, y: 610))
        vane.addCurve(to: CGPoint(x: 512, y: 150), control1: CGPoint(x: 428, y: 380), control2: CGPoint(x: 462, y: 230))
        vane.closeSubpath()
        let shaft = CGMutablePath()
        shaft.move(to: CGPoint(x: 500, y: 700)); shaft.addLine(to: CGPoint(x: 526, y: 700))
        shaft.addLine(to: CGPoint(x: 512, y: 900)); shaft.closeSubpath()
        guard let quillVane = vane.copy(using: &transform), let quillTip = shaft.copy(using: &transform) else { return }
        let band = CGPath(roundedRect: CGRect(x: 196, y: 556, width: 632, height: 132), cornerWidth: 26, cornerHeight: 26, transform: nil)

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(band); context.fillPath()
        for (x, knob) in [(CGFloat(196), CGFloat(520)), (828, 724)] {
            context.addEllipse(in: CGRect(x: x - 34, y: knob - 34, width: 68, height: 68)); context.fillPath()
        }
        // A gap around the quill, so it reads in front of the selection.
        context.setBlendMode(.clear)
        context.addPath(quillVane); context.setLineWidth(60); context.strokePath()
        context.addPath(quillTip); context.setLineWidth(50); context.strokePath()
        context.setBlendMode(.normal)
        context.addPath(quillVane); context.fillPath()
        context.addPath(quillTip); context.fillPath()
        context.endTransparencyLayer()
    }
}
