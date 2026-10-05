#if DEBUG

import AppKit
import ApplicationServices

/// `QUILL_DUMP_A11Y` (ARCHITECTURE §3.6, PLAN P5-T3): prints the real accessibility tree of
/// a window, as VoiceOver reads it, for `Scripts/check-accessibility.sh`. Adapted from
/// Ámbar's `AccessibilityDump`, with the same two lessons: the walk is bounded by identity
/// (the application publishes itself as its own child), and the window is found by
/// hit-testing its centre, not through `kAXWindowsAttribute`, which was unreliable.
enum AccessibilityDump {
    struct Element {
        let depth: Int
        let role: String
        let subrole: String
        let label: String
        let size: CGSize
    }

    static func walk(_ element: AXUIElement, depth: Int = 0, into result: inout [Element], seen: inout [AXUIElement]) {
        guard depth < 40 else { return }
        if seen.contains(where: { CFEqual($0, element) }) { return }
        seen.append(element)

        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            guard let text = value as? String, !text.isEmpty else { return nil }
            return text
        }

        var size = CGSize.zero
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let axValue = sizeValue, CFGetTypeID(axValue) == AXValueGetTypeID() {
            AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        }
        // As VoiceOver resolves a name: the element's own description or title, else the
        // element that titles it (a Form row's label), else a placeholder or the value.
        var titleElementName: String?
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &titleValue) == .success,
           let titleElement = titleValue, CFGetTypeID(titleElement) == AXUIElementGetTypeID() {
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var named: CFTypeRef?
                if AXUIElementCopyAttributeValue(titleElement as! AXUIElement, attribute as CFString, &named) == .success,
                   let text = named as? String, !text.isEmpty {
                    titleElementName = text
                    break
                }
            }
        }
        let label = string(kAXDescriptionAttribute) ?? string(kAXTitleAttribute) ?? titleElementName
            ?? string(kAXPlaceholderValueAttribute) ?? string(kAXValueAttribute) ?? ""
        result.append(Element(depth: depth, role: string(kAXRoleAttribute) ?? "-", subrole: string(kAXSubroleAttribute) ?? "-",
                              label: label.replacingOccurrences(of: "\n", with: " "), size: size))

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1, into: &result, seen: &seen) }
    }

    /// Prints `A11Y <surface> <depth> <role> <subrole> <w>x<h> <label>` for every element of `window`.
    @MainActor
    static func dump(_ window: NSWindow, surface: String) {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let screen = window.screen ?? NSScreen.main else {
            print("A11Y ERROR \(surface): no screen to find the window on")
            return
        }
        // Accessibility's origin is the top left; AppKit's, the bottom left.
        let center = CGPoint(x: window.frame.midX, y: screen.frame.maxY - window.frame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(center.x), Float(center.y), &hit) == .success,
              let element = hit else {
            print("A11Y ERROR \(surface): nothing accessible at the window's centre")
            return
        }
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let found = windowValue, CFGetTypeID(found) == AXUIElementGetTypeID() else {
            // Not on screen: a precondition that failed, not a missing label. Saying so
            // keeps the check from reporting a defect it could not measure.
            print("A11Y ERROR \(surface): the window is not on screen (no graphical session?)")
            return
        }
        var elements: [Element] = []
        var seen: [AXUIElement] = []
        walk(found as! AXUIElement, into: &elements, seen: &seen)
        for element in elements {
            let size = "\(Int(element.size.width.rounded()))x\(Int(element.size.height.rounded()))"
            print("A11Y \(surface) \(element.depth) \(element.role) \(element.subrole) \(size) \(element.label)")
        }
        print("A11Y TOTAL \(surface) \(elements.count)")
        fflush(stdout)
    }
}

#endif
