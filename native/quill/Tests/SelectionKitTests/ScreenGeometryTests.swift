import CoreGraphics
import Testing

@testable import SelectionKit

@Suite("Accessibility → Cocoa coordinates")
struct ScreenGeometryTests {
    @Test("a rect near the top of the primary screen lands near its top in Cocoa")
    func topOfPrimaryScreen() {
        // A 1440×900 primary screen; a selection 100 pt from the top, 20 pt tall.
        let accessibility = CGRect(x: 50, y: 100, width: 200, height: 20)
        let cocoa = ScreenGeometry.cocoaRect(fromAccessibility: accessibility, primaryScreenHeight: 900)
        #expect(cocoa == CGRect(x: 50, y: 780, width: 200, height: 20))
    }

    @Test("converting twice returns the original rect")
    func roundTrip() {
        let rect = CGRect(x: -300, y: 1200, width: 80, height: 40)
        let once = ScreenGeometry.cocoaRect(fromAccessibility: rect, primaryScreenHeight: 1117)
        #expect(ScreenGeometry.cocoaRect(fromAccessibility: once, primaryScreenHeight: 1117) == rect)
    }

    @Test("a secondary screen above the primary has negative accessibility y")
    func screenAbovePrimary() {
        let accessibility = CGRect(x: 0, y: -500, width: 10, height: 10)
        let cocoa = ScreenGeometry.cocoaRect(fromAccessibility: accessibility, primaryScreenHeight: 900)
        #expect(cocoa.minY == 1390)
    }

    @Test("the containing screen is found, and the nearest one when none contains the point")
    func containingScreen() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(ScreenGeometry.screen(containing: CGPoint(x: 2000, y: 500), in: [primary, right]) == right)
        #expect(ScreenGeometry.screen(containing: CGPoint(x: -40, y: 300), in: [primary, right]) == primary)
        #expect(ScreenGeometry.screen(containing: .zero, in: []) == nil)
    }

    @Test("clamping moves a rect the least needed to fit the frame")
    func clamp() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(ScreenGeometry.clamp(CGRect(x: 950, y: 10, width: 100, height: 50), into: frame).minX == 900)
        #expect(ScreenGeometry.clamp(CGRect(x: -20, y: 790, width: 100, height: 50), into: frame)
            == CGRect(x: 0, y: 750, width: 100, height: 50))
        let inside = CGRect(x: 10, y: 10, width: 10, height: 10)
        #expect(ScreenGeometry.clamp(inside, into: frame) == inside)
        let huge = ScreenGeometry.clamp(CGRect(x: 30, y: 30, width: 2000, height: 2000), into: frame)
        #expect(huge.minX == 0 && huge.maxY == 800)
    }
}
