import CoreGraphics
import Testing

@testable import SelectionKit

/// The picker's placement from the selection's bounds (PLAN P2-T4), on fixed geometries.
@Suite("Selection bounds and picker placement")
struct BoundsTests {
    /// A 1440 × 900 main screen (menu bar 25 pt, Dock 60 pt), a 1920 × 1080 display
    /// above it, and a 1280 × 1024 display to its left.
    let main = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 60, width: 1440, height: 815))
    let above = (frame: CGRect(x: -240, y: 900, width: 1920, height: 1080), visibleFrame: CGRect(x: -240, y: 900, width: 1920, height: 1055))
    let left = (frame: CGRect(x: -1280, y: -124, width: 1280, height: 1024), visibleFrame: CGRect(x: -1280, y: -124, width: 1280, height: 999))
    let panel = CGSize(width: 360, height: 220)

    var screens: [(frame: CGRect, visibleFrame: CGRect)] { [main, above, left] }

    /// Accessibility (top-left of the main screen, y down) → Cocoa, then placement.
    private func place(accessibility rect: CGRect) -> CGPoint {
        let cocoa = ScreenGeometry.cocoaRect(fromAccessibility: rect, primaryScreenHeight: main.frame.height)
        return PickerPlacement.origin(panelSize: panel, anchor: cocoa, mouse: .zero, screens: screens)
    }

    @Test("on the main screen the picker sits just below the selection")
    func mainScreen() {
        // A selection 300 pt from the top: Cocoa y 586…600.
        let origin = place(accessibility: CGRect(x: 200, y: 300, width: 120, height: 14))
        #expect(origin == CGPoint(x: 200, y: 586 - 6 - 220))
    }

    @Test("near the bottom of the screen it goes above the selection")
    func flipsAbove() {
        let origin = place(accessibility: CGRect(x: 200, y: 780, width: 120, height: 14))
        // Cocoa y of the selection: 106…120; below would end under the Dock.
        #expect(origin == CGPoint(x: 200, y: 120 + 6))
    }

    @Test("a selection on a display above the main one is placed on that display")
    func displayAbove() {
        // Accessibility y is negative above the main screen.
        let origin = place(accessibility: CGRect(x: 100, y: -500, width: 80, height: 14))
        let cocoaTop = 900 + 500 - 14   // Cocoa minY of the selection
        #expect(origin.y == CGFloat(cocoaTop) - 6 - 220)
        #expect(above.visibleFrame.contains(CGRect(origin: origin, size: panel)))
    }

    @Test("a selection on a display to the left is placed on that display, clamped to its edge")
    func displayToTheLeft() {
        let origin = place(accessibility: CGRect(x: -100, y: 400, width: 90, height: 14))
        // 360 pt wide from x = -100 would cross onto the main screen: clamped to end at x = 0.
        #expect(origin.x == -360)
        #expect(left.visibleFrame.contains(CGRect(origin: origin, size: panel)))
    }

    @Test("near the right edge it is clamped inside the visible frame")
    func rightEdge() {
        let origin = place(accessibility: CGRect(x: 1400, y: 300, width: 30, height: 14))
        #expect(origin.x == CGFloat(1440 - 360))
    }

    @Test("without bounds the mouse location is used")
    func mouseFallback() {
        let origin = PickerPlacement.origin(panelSize: panel, anchor: nil, mouse: CGPoint(x: 700, y: 500), screens: screens)
        #expect(origin == CGPoint(x: 700, y: 500 - 6 - 220))
    }

    @Test("a point off every screen uses the nearest one")
    func offScreen() {
        // (3005, 405) is nearer the upper display, which reaches x = 1680, than the main one.
        let origin = PickerPlacement.origin(panelSize: panel, anchor: CGRect(x: 3000, y: 400, width: 10, height: 10),
                                            mouse: .zero, screens: screens)
        #expect(above.visibleFrame.contains(CGRect(origin: origin, size: panel)))
        let nearMain = PickerPlacement.origin(panelSize: panel, anchor: CGRect(x: 1500, y: 300, width: 10, height: 10),
                                              mouse: .zero, screens: screens)
        #expect(main.visibleFrame.contains(CGRect(origin: nearMain, size: panel)))
    }
}
