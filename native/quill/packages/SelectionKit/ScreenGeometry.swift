import CoreGraphics

/// Converts between the Accessibility API's coordinates and Cocoa's (ARCHITECTURE §3.1
/// step 7).
///
/// The Accessibility API uses global coordinates with the origin at the **top-left** of
/// the primary screen and y growing down. Cocoa uses the **bottom-left** of the primary
/// screen with y growing up. Both share the primary screen's height as the pivot.
public enum ScreenGeometry {
    /// A rectangle from accessibility coordinates to Cocoa screen coordinates.
    public static func cocoaRect(fromAccessibility rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The screen frame that contains `point`, or the one nearest to it.
    public static func screen(containing point: CGPoint, in screens: [CGRect]) -> CGRect? {
        if let containing = screens.first(where: { $0.contains(point) }) { return containing }
        return screens.min { distance(from: point, to: $0) < distance(from: point, to: $1) }
    }

    /// Moves `rect` the least needed to lie inside `frame`. A rect larger than the frame
    /// is pinned to its top-left corner (in Cocoa coordinates: minX, maxY).
    public static func clamp(_ rect: CGRect, into frame: CGRect) -> CGRect {
        var result = rect
        if result.width >= frame.width {
            result.origin.x = frame.minX
        } else {
            result.origin.x = min(max(result.minX, frame.minX), frame.maxX - result.width)
        }
        if result.height >= frame.height {
            result.origin.y = frame.maxY - result.height
        } else {
            result.origin.y = min(max(result.minY, frame.minY), frame.maxY - result.height)
        }
        return result
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Where the picker goes (ARCHITECTURE §3.1 step 7): below the selection, or above it
/// when there is no room, on the screen that holds it, inside that screen's visible frame.
public enum PickerPlacement {
    /// The gap between the selection and the panel.
    public static let gap: CGFloat = 6

    /// - Parameters:
    ///   - anchor: the selection's bounds in Cocoa coordinates, or nil to use `mouse`.
    ///   - screens: each screen's full and visible frames, in Cocoa coordinates.
    public static func origin(
        panelSize: CGSize, anchor: CGRect?, mouse: CGPoint, screens: [(frame: CGRect, visibleFrame: CGRect)]
    ) -> CGPoint {
        let anchor = anchor ?? CGRect(origin: mouse, size: .zero)
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = screens.first { $0.frame.contains(center) }
            ?? screens.min { ScreenGeometry.distance(from: center, to: $0.frame) < ScreenGeometry.distance(from: center, to: $1.frame) }
        guard let visible = screen?.visibleFrame else { return anchor.origin }
        let below = CGRect(x: anchor.minX, y: anchor.minY - gap - panelSize.height, width: panelSize.width, height: panelSize.height)
        let above = CGRect(x: anchor.minX, y: anchor.maxY + gap, width: panelSize.width, height: panelSize.height)
        let preferred = below.minY >= visible.minY ? below : (above.maxY <= visible.maxY ? above : below)
        return ScreenGeometry.clamp(preferred, into: visible).origin
    }
}
