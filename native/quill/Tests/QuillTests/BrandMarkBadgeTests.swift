import AppKit
import Testing

@testable import Quill

/// The menu bar mark with and without the "new version" dot.
@Suite("Brand mark badge")
@MainActor
struct BrandMarkBadgeTests {
    /// Opaque pixels in the top-right corner, where the dot goes.
    static func cornerInk(_ image: NSImage) -> Int {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        var ink = 0
        for x in 26..<34 { for y in 2..<10 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 } }
        return ink
    }

    @Test("the badged mark carries a dot in its corner; the plain one does not, and both stay templates")
    func badge() {
        let plain = BrandMark.menuBarImage(accessibilityDescription: "Quill")
        let badged = BrandMark.menuBarImage(accessibilityDescription: "Quill", badged: true)
        #expect(Self.cornerInk(badged) > Self.cornerInk(plain) + 10)
        #expect(plain.isTemplate && badged.isTemplate)
    }
}
