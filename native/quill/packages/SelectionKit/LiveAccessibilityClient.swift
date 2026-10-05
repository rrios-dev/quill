import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The real Accessibility API.
///
/// Every call may block for the host's messaging timeout, so callers run these off
/// the main thread (ARCHITECTURE §3.1).
public struct LiveAccessibilityClient: AccessibilityClient {
    public init() {}

    public func isProcessTrusted() -> Bool { AXIsProcessTrusted() }

    public func systemWide() -> AccessibilityElement {
        AccessibilityElement(AXUIElementCreateSystemWide())
    }

    public func application(pid: pid_t) -> AccessibilityElement {
        AccessibilityElement(AXUIElementCreateApplication(pid))
    }

    public func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func pid(of element: AccessibilityElement) -> pid_t? {
        guard let ax = element.axElement else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(ax, &pid) == .success ? pid : nil
    }

    public func setMessagingTimeout(_ seconds: Float, on element: AccessibilityElement) {
        guard let ax = element.axElement else { return }
        _ = AXUIElementSetMessagingTimeout(ax, seconds)
    }

    private func copy(_ attribute: String, of element: AccessibilityElement) -> Result<CFTypeRef, AccessibilityError> {
        guard let ax = element.axElement else { return .failure(.invalidElement) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ax, attribute as CFString, &value)
        guard error == .success else { return .failure(AccessibilityError(error)) }
        guard let value else { return .failure(.noValue) }
        return .success(value)
    }

    public func element(_ attribute: String, of element: AccessibilityElement) -> Result<AccessibilityElement, AccessibilityError> {
        copy(attribute, of: element).flatMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failure(.unexpectedType) }
            return .success(AccessibilityElement(unsafeDowncast(value, to: AXUIElement.self)))
        }
    }

    public func string(_ attribute: String, of element: AccessibilityElement) -> Result<String, AccessibilityError> {
        copy(attribute, of: element).flatMap { value in
            guard let string = value as? String else { return .failure(.unexpectedType) }
            return .success(string)
        }
    }

    public func strings(_ attribute: String, of element: AccessibilityElement) -> Result<[String], AccessibilityError> {
        copy(attribute, of: element).flatMap { value in
            guard let strings = value as? [String] else { return .failure(.unexpectedType) }
            return .success(strings)
        }
    }

    public func range(_ attribute: String, of element: AccessibilityElement) -> Result<CFRange, AccessibilityError> {
        copy(attribute, of: element).flatMap { value in
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return .failure(.unexpectedType) }
            var range = CFRange()
            guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return .failure(.unexpectedType) }
            return .success(range)
        }
    }

    public func isSettable(_ attribute: String, of element: AccessibilityElement) -> Result<Bool, AccessibilityError> {
        guard let ax = element.axElement else { return .failure(.invalidElement) }
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(ax, attribute as CFString, &settable)
        guard error == .success else { return .failure(AccessibilityError(error)) }
        return .success(settable.boolValue)
    }

    public func setString(_ value: String, for attribute: String, of element: AccessibilityElement) -> Result<Void, AccessibilityError> {
        set(value as CFString, for: attribute, of: element)
    }

    public func setBool(_ value: Bool, for attribute: String, of element: AccessibilityElement) -> Result<Void, AccessibilityError> {
        set((value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef, for: attribute, of: element)
    }

    private func set(_ value: CFTypeRef, for attribute: String, of element: AccessibilityElement) -> Result<Void, AccessibilityError> {
        guard let ax = element.axElement else { return .failure(.invalidElement) }
        let error = AXUIElementSetAttributeValue(ax, attribute as CFString, value)
        return error == .success ? .success(()) : .failure(AccessibilityError(error))
    }

    private func parameterized(
        _ attribute: String, range: CFRange, of element: AccessibilityElement
    ) -> Result<CFTypeRef, AccessibilityError> {
        guard let ax = element.axElement else { return .failure(.invalidElement) }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return .failure(.unexpectedType) }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(ax, attribute as CFString, parameter, &value)
        guard error == .success else { return .failure(AccessibilityError(error)) }
        guard let value else { return .failure(.noValue) }
        return .success(value)
    }

    public func attributeRuns(in range: CFRange, of element: AccessibilityElement) -> Result<[AttributeRun], AccessibilityError> {
        parameterized("AXAttributedStringForRange", range: range, of: element).flatMap { value in
            guard let attributed = value as? NSAttributedString else { return .failure(.unexpectedType) }
            var runs: [AttributeRun] = []
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, _ in
                runs.append(Self.run(from: attributes))
            }
            return .success(runs)
        }
    }

    /// Reads one run's attributes. Keys are the accessibility attributed-string keys,
    /// as literals (`kAXFontTextAttribute` and its siblings are global `var`s in Swift).
    static func run(from attributes: [NSAttributedString.Key: Any]) -> AttributeRun {
        let font = attributes[NSAttributedString.Key("AXFont")] as? [String: Any]
        let underline = (attributes[NSAttributedString.Key("AXUnderline")] as? NSNumber)?.intValue ?? 0
        return AttributeRun(
            fontName: font?["AXFontName"] as? String,
            underline: underline,
            hasLink: attributes[NSAttributedString.Key("AXLink")] != nil,
            hasListItemPrefix: attributes[NSAttributedString.Key("AXListItemPrefix")] != nil
        )
    }

    public func selectedTextViaTextMarkers(of element: AccessibilityElement) -> Result<String, AccessibilityError> {
        guard let ax = element.axElement else { return .failure(.invalidElement) }
        return copy("AXSelectedTextMarkerRange", of: element).flatMap { markerRange in
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(
                ax, "AXStringForTextMarkerRange" as CFString, markerRange, &value)
            guard error == .success else { return .failure(AccessibilityError(error)) }
            guard let string = value as? String else { return .failure(.unexpectedType) }
            return .success(string)
        }
    }

    public func bounds(for range: CFRange, of element: AccessibilityElement) -> Result<CGRect, AccessibilityError> {
        parameterized("AXBoundsForRange", range: range, of: element).flatMap { value in
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return .failure(.unexpectedType) }
            var rect = CGRect.zero
            guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect) else { return .failure(.unexpectedType) }
            return .success(rect)
        }
    }
}
