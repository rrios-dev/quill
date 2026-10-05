import CoreGraphics
import Foundation

@testable import SelectionKit

/// One ordered record of every side effect the fakes see, so tests assert the **order**
/// of capture and replace (ARCHITECTURE §3.7).
final class EffectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }

    /// Whether `first` happened before `second` (both present).
    func happened(_ first: String, before second: String) -> Bool {
        let all = all
        guard let a = all.firstIndex(where: { $0.hasPrefix(first) }),
              let b = all.firstIndex(where: { $0.hasPrefix(second) }) else { return false }
        return a < b
    }
}

// MARK: Clock

/// A `Clock` whose sleeps return at once, advancing its time: waits and caps run in
/// microseconds and deterministically.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    let log: EffectLog?
    /// Called on every advance with the new time — fakes use it to change state over time.
    var onAdvance: (@Sendable (Duration) -> Void)?

    init(log: EffectLog? = nil) { self.log = log }

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var elapsed: Duration { now.offset }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let time: Duration = lock.withLock {
            if deadline > current { current = deadline }
            return current.offset
        }
        onAdvance?(time)
        await Task.yield()
    }

    func advance(by duration: Duration) {
        let time: Duration = lock.withLock {
            current = current.advanced(by: duration)
            return current.offset
        }
        onAdvance?(time)
    }
}

// MARK: Accessibility

/// A scripted accessibility tree: elements by name, each with attribute values, settable
/// attributes and injected errors.
final class FakeAccessibility: AccessibilityClient, @unchecked Sendable {
    enum Value {
        case string(String)
        case strings([String])
        case range(CFRange)
        case element(String)
    }

    struct Node {
        var pid: pid_t = 1
        var values: [String: Value] = [:]
        var settable: Set<String> = []
        var errors: [String: AccessibilityError] = [:]
        var runs: [AttributeRun]?
        var bounds: CGRect?
    }

    private let lock = NSLock()
    var nodes: [String: Node] = [:]
    /// The system-wide focused element, or the error the system-wide query answers.
    var systemFocus: Result<String, AccessibilityError> = .failure(.noValue)
    /// Per application: its focused element.
    var applicationFocus: [pid_t: Result<String, AccessibilityError>] = [:]
    var frontmost: pid_t? = 1
    var trusted = true
    let log: EffectLog?
    /// Called when an app is asked to build its tree (`AXManualAccessibility = true`).
    var onManualAccessibility: ((pid_t) -> Void)?
    private(set) var manualAccessibilityRequests: [pid_t] = []
    private(set) var enhancedRequests: [pid_t] = []
    private(set) var writes: [(element: String, text: String)] = []
    private(set) var messagingTimeouts: [Float] = []

    init(log: EffectLog? = nil) { self.log = log }

    func update(_ body: (FakeAccessibility) -> Void) { lock.withLock { body(self) } }

    private func name(_ element: AccessibilityElement) -> String? {
        if case .fake(let name) = element.storage { return name }
        return nil
    }

    func isProcessTrusted() -> Bool { trusted }
    func systemWide() -> AccessibilityElement { AccessibilityElement(fake: "systemWide") }
    func application(pid: pid_t) -> AccessibilityElement { AccessibilityElement(fake: "app:\(pid)") }
    func frontmostApplicationPID() -> pid_t? { frontmost }

    func pid(of element: AccessibilityElement) -> pid_t? {
        guard let name = name(element) else { return nil }
        if name.hasPrefix("app:") { return pid_t(name.dropFirst(4)) }
        return lock.withLock { nodes[name]?.pid }
    }

    func setMessagingTimeout(_ seconds: Float, on element: AccessibilityElement) {
        lock.withLock { messagingTimeouts.append(seconds) }
    }

    func element(_ attribute: String, of element: AccessibilityElement) -> Result<AccessibilityElement, AccessibilityError> {
        guard let name = name(element) else { return .failure(.invalidElement) }
        return lock.withLock { () -> Result<AccessibilityElement, AccessibilityError> in
            if attribute == "AXFocusedUIElement" {
                if name == "systemWide" { return systemFocus.map { AccessibilityElement(fake: $0) } }
                if name.hasPrefix("app:"), let pid = pid_t(name.dropFirst(4)) {
                    return (applicationFocus[pid] ?? .failure(.noValue)).map { AccessibilityElement(fake: $0) }
                }
            }
            if attribute == "AXFocusedApplication", name == "systemWide" {
                guard let target = (try? systemFocus.get()), let pid = nodes[target]?.pid else { return .failure(.noValue) }
                return .success(AccessibilityElement(fake: "app:\(pid)"))
            }
            if let error = nodes[name]?.errors[attribute] { return .failure(error) }
            if case .element(let target)? = nodes[name]?.values[attribute] { return .success(AccessibilityElement(fake: target)) }
            return .failure(.noValue)
        }
    }

    private func value(_ attribute: String, _ element: AccessibilityElement) -> Result<Value, AccessibilityError> {
        guard let name = name(element) else { return .failure(.invalidElement) }
        return lock.withLock {
            guard let node = nodes[name] else { return .failure(.invalidElement) }
            if let error = node.errors[attribute] { return .failure(error) }
            guard let value = node.values[attribute] else { return .failure(.noValue) }
            return .success(value)
        }
    }

    func string(_ attribute: String, of element: AccessibilityElement) -> Result<String, AccessibilityError> {
        if attribute == "AXSelectedText" || attribute == "AXValue" { log?.append("read:\(attribute)") }
        return value(attribute, element).flatMap { if case .string(let s) = $0 { .success(s) } else { .failure(.unexpectedType) } }
    }

    func strings(_ attribute: String, of element: AccessibilityElement) -> Result<[String], AccessibilityError> {
        value(attribute, element).flatMap { if case .strings(let s) = $0 { .success(s) } else { .failure(.unexpectedType) } }
    }

    func range(_ attribute: String, of element: AccessibilityElement) -> Result<CFRange, AccessibilityError> {
        value(attribute, element).flatMap { if case .range(let r) = $0 { .success(r) } else { .failure(.unexpectedType) } }
    }

    func isSettable(_ attribute: String, of element: AccessibilityElement) -> Result<Bool, AccessibilityError> {
        guard let name = name(element) else { return .failure(.invalidElement) }
        return lock.withLock {
            guard let node = nodes[name] else { return .failure(.invalidElement) }
            return .success(node.settable.contains(attribute))
        }
    }

    func setString(_ value: String, for attribute: String, of element: AccessibilityElement) -> Result<Void, AccessibilityError> {
        guard let name = name(element) else { return .failure(.invalidElement) }
        log?.append("axWrite:\(attribute)")
        return lock.withLock {
            writes.append((name, value))
            if attribute == "AXSelectedText", var node = nodes[name], case .string(let old)? = node.values["AXValue"],
               case .string(let selected)? = node.values["AXSelectedText"] {
                node.values["AXValue"] = .string(old.replacingOccurrences(of: selected, with: value))
                nodes[name] = node
            }
            return .success(())
        }
    }

    func setBool(_ value: Bool, for attribute: String, of element: AccessibilityElement) -> Result<Void, AccessibilityError> {
        guard let name = name(element), name.hasPrefix("app:"), let pid = pid_t(name.dropFirst(4)) else {
            return .failure(.attributeUnsupported)
        }
        log?.append("\(attribute):\(pid)")
        let callback: ((pid_t) -> Void)? = lock.withLock {
            if attribute == "AXManualAccessibility" { manualAccessibilityRequests.append(pid); return onManualAccessibility }
            if attribute == "AXEnhancedUserInterface" { enhancedRequests.append(pid) }
            return nil
        }
        callback?(pid)
        return .success(())
    }

    func attributeRuns(in range: CFRange, of element: AccessibilityElement) -> Result<[AttributeRun], AccessibilityError> {
        guard let name = name(element) else { return .failure(.invalidElement) }
        return lock.withLock { nodes[name]?.runs.map { .success($0) } ?? .failure(.attributeUnsupported) }
    }

    func selectedTextViaTextMarkers(of element: AccessibilityElement) -> Result<String, AccessibilityError> {
        .failure(.attributeUnsupported)
    }

    func bounds(for range: CFRange, of element: AccessibilityElement) -> Result<CGRect, AccessibilityError> {
        guard let name = name(element) else { return .failure(.invalidElement) }
        return lock.withLock { nodes[name]?.bounds.map { .success($0) } ?? .failure(.attributeUnsupported) }
    }
}

// MARK: Pasteboard

/// An in-memory pasteboard with an injectable access policy, reads that can block, and
/// a record of every write.
final class FakePasteboard: PasteboardClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PasteboardItemData]
    private var count = 1
    var access: PasteboardAccess
    let log: EffectLog?
    /// Reads of these types wait on `release` — a lazily provided type that never comes.
    var blockingTypes: Set<String> = []
    let release = DispatchSemaphore(value: 0)
    private(set) var reads = 0
    private(set) var writes: [(items: [PasteboardItemData], hostOnly: Bool)] = []
    /// What the "host" does when it receives ⌘C: put this on the pasteboard.
    var hostCopy: PasteboardItemData?

    init(items: [PasteboardItemData] = [], access: PasteboardAccess = .alwaysAllow, log: EffectLog? = nil) {
        self.items = items
        self.access = access
        self.log = log
    }

    func changeCount() -> Int { lock.withLock { count } }
    func accessBehavior() -> PasteboardAccess { access }

    func itemTypes() -> [[String]] {
        log?.append("pasteboardRead")
        return lock.withLock { reads += 1; return items.map(\.types) }
    }

    func data(forType type: String, item index: Int) -> Data? {
        if blockingTypes.contains(type) { release.wait() }
        return lock.withLock {
            reads += 1
            return items.indices.contains(index) ? items[index].data(forType: type) : nil
        }
    }

    func string() -> String? {
        lock.withLock {
            reads += 1
            return items.first?.data(forType: "public.utf8-plain-text").flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    @discardableResult
    func write(_ newItems: [PasteboardItemData], hostOnly: Bool) -> Int {
        let isRestore = newItems.first?.data(forType: PasteboardMarkers.concealed) == nil
        log?.append(isRestore ? "restore" : "write")
        return lock.withLock {
            items = newItems
            count += 1
            writes.append((newItems, hostOnly))
            return count
        }
    }

    /// The host copying the selection after ⌘C.
    func simulateHostCopy() {
        guard let hostCopy else { return }
        lock.withLock {
            items = [hostCopy]
            count += 1
        }
    }

    /// Someone else (the user) copying meanwhile.
    func simulateUserCopy(_ text: String) {
        lock.withLock {
            items = [PasteboardItemData(entries: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])]
            count += 1
        }
    }

    var currentItems: [PasteboardItemData] { lock.withLock { items } }
}

// MARK: Keys

/// Records posted shortcuts and answers key and modifier state from a script over time.
final class FakeKeys: KeyEventPoster, @unchecked Sendable {
    private let lock = NSLock()
    let log: EffectLog?
    private(set) var posted: [Character] = []
    /// Modifiers physically held, as a function of the elapsed time.
    var modifiers: @Sendable () -> HeldModifiers = { [] }
    /// Keys physically down.
    var keysDown: @Sendable (CGKeyCode) -> Bool = { _ in false }
    /// What happens when a shortcut is posted (the host reacting).
    var onPost: (@Sendable (Character) -> Void)?

    init(log: EffectLog? = nil) { self.log = log }

    func postCommandShortcut(_ letter: Character) async -> Bool {
        log?.append("cmd\(String(letter).uppercased())")
        lock.withLock { posted.append(letter) }
        onPost?(letter)
        return true
    }

    func isKeyDown(_ keyCode: CGKeyCode) -> Bool { keysDown(keyCode) }
    func heldModifiers() -> HeldModifiers { modifiers() }

    var postedShortcuts: [Character] { lock.withLock { posted } }
}

func textItem(_ text: String) -> PasteboardItemData {
    PasteboardItemData(entries: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])
}
