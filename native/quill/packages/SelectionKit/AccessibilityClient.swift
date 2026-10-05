import ApplicationServices
import CoreGraphics
import Foundation

/// A UI element in another app, as the Accessibility API sees it.
///
/// Wraps `AXUIElement` for the live client and a plain identifier for fakes, so tests
/// can script element trees without the API. Equality is `CFEqual` for live elements,
/// which is what ARCHITECTURE §3.2 step 3 compares.
public struct AccessibilityElement: Hashable, @unchecked Sendable {
    enum Storage: Hashable {
        case live(AXUIElement)
        case fake(String)
    }

    let storage: Storage

    public init(_ element: AXUIElement) { storage = .live(element) }

    /// An element for fakes; the identifier names it in test failures.
    public init(fake identifier: String) { storage = .fake(identifier) }

    var axElement: AXUIElement? {
        if case .live(let element) = storage { return element }
        return nil
    }
}

/// Why an accessibility call returned nothing.
public enum AccessibilityError: Error, Equatable, Sendable {
    /// `kAXErrorCannotComplete`: how a busy, timed-out or still-building host answers.
    case cannotComplete
    /// `kAXErrorAttributeUnsupported` / `kAXErrorParameterizedAttributeUnsupported`.
    case attributeUnsupported
    /// `kAXErrorNoValue`: the attribute exists and is empty.
    case noValue
    /// `kAXErrorAPIDisabled`: Quill is not trusted for accessibility.
    case notTrusted
    /// `kAXErrorInvalidUIElement`: the element is gone.
    case invalidElement
    /// The value had an unexpected type.
    case unexpectedType
    case other(Int32)

    public init(_ error: AXError) {
        switch error {
        case .cannotComplete: self = .cannotComplete
        case .attributeUnsupported, .parameterizedAttributeUnsupported: self = .attributeUnsupported
        case .noValue: self = .noValue
        case .apiDisabled: self = .notTrusted
        case .invalidUIElement: self = .invalidElement
        default: self = .other(error.rawValue)
        }
    }
}

/// The Accessibility API, behind a seam (ARCHITECTURE §3.7).
///
/// Attribute names are passed as their string values (`"AXSelectedText"`), not the
/// SDK's global constants, as `AppCore.Paster` does: several of those are imported as
/// global `var`s, which Swift 6 does not accept from concurrent code.
public protocol AccessibilityClient: Sendable {
    func isProcessTrusted() -> Bool
    func systemWide() -> AccessibilityElement
    func application(pid: pid_t) -> AccessibilityElement
    func frontmostApplicationPID() -> pid_t?
    func pid(of element: AccessibilityElement) -> pid_t?

    /// Applies to the object it is set on; on the system-wide element, process-wide.
    func setMessagingTimeout(_ seconds: Float, on element: AccessibilityElement)

    func element(_ attribute: String, of element: AccessibilityElement) -> Result<AccessibilityElement, AccessibilityError>
    func string(_ attribute: String, of element: AccessibilityElement) -> Result<String, AccessibilityError>
    func strings(_ attribute: String, of element: AccessibilityElement) -> Result<[String], AccessibilityError>
    func range(_ attribute: String, of element: AccessibilityElement) -> Result<CFRange, AccessibilityError>
    func isSettable(_ attribute: String, of element: AccessibilityElement) -> Result<Bool, AccessibilityError>
    func setString(_ value: String, for attribute: String, of element: AccessibilityElement) -> Result<Void, AccessibilityError>
    func setBool(_ value: Bool, for attribute: String, of element: AccessibilityElement) -> Result<Void, AccessibilityError>

    /// `kAXAttributedStringForRangeParameterizedAttribute`: the attribute runs of a range.
    func attributeRuns(in range: CFRange, of element: AccessibilityElement) -> Result<[AttributeRun], AccessibilityError>

    /// The selected text as WebKit exposes it: `AXSelectedTextMarkerRange` turned into a
    /// string with `AXStringForTextMarkerRange`. WebKit editors such as Mail's message
    /// body answer the selection only this way; `kAXSelectedText` reports no value there.
    func selectedTextViaTextMarkers(of element: AccessibilityElement) -> Result<String, AccessibilityError>

    /// `kAXBoundsForRangeParameterizedAttribute`, in the API's top-left global coordinates.
    func bounds(for range: CFRange, of element: AccessibilityElement) -> Result<CGRect, AccessibilityError>
}

/// The attributes of one run of an accessibility attributed string, reduced to what
/// rich-format detection reads (ARCHITECTURE §3.1 step 6).
public struct AttributeRun: Equatable, Sendable {
    public var fontName: String?
    /// `AXUnderline`: the underline style; 0 means none.
    public var underline: Int
    public var hasLink: Bool
    public var hasListItemPrefix: Bool

    public init(fontName: String? = nil, underline: Int = 0, hasLink: Bool = false, hasListItemPrefix: Bool = false) {
        self.fontName = fontName
        self.underline = underline
        self.hasLink = hasLink
        self.hasListItemPrefix = hasListItemPrefix
    }
}
