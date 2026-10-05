import AppKit
import QuillSupport
import SelectionKit

/// The send-only Services entry "Rewrite with Quill" (ARCHITECTURE §5.1).
///
/// A send-and-return service would have to hand back its result while the host waits
/// blocked, which an interactive picker cannot do. So the handler only copies the text
/// and returns at once — the host's main thread is blocked until it does, and an
/// accessibility query from inside the handler would time out against it — and the
/// rest happens afterwards: the focused element is read, its selection compared with
/// the delivered text, and the picker opens.
@MainActor
final class ServicesProvider: NSObject {
    /// Called with the delivered text after the handler has returned.
    var onText: (String) -> Void = { _ in }

    /// `NSMessage` in Info.plist's `NSServices`.
    @objc func rewriteText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let deliver = onText
        // After the run loop turn that returns to the host.
        DispatchQueue.main.async { deliver(text) }
    }

    /// The capture for a delivered text: the focused element through accessibility, with
    /// the settable rule only when its selection is the delivered text; anything else is
    /// uncertain, and terminals stay read-only-only (ARCHITECTURE §3.1 step 5).
    nonisolated static func capture(text: String, app: AppIdentity, operations: SelectionOperations,
                        primaryScreenHeight: CGFloat) -> Result<Capture, CaptureRefusal> {
        let focusResult = operations.focusedElement()
        let focused = try? focusResult.get()
        let read = focused.map { operations.readSelection(of: $0.element) }
        QuillLog(category: "services").debug(
            "capture: focus \(focused.map { "\($0.path)" } ?? "failed: \(focusResult)"), role \(read?.role ?? "-"), "
            + "text \(read?.text?.count ?? -1) of \(text.count), settable \(read?.selectedTextSettable.map(String.init) ?? "-")")
        if read?.isSecureField == true { return .failure(.passwordField) }
        let strategy = AppStrategy.strategy(for: app.bundleIdentifier)
        let editability = editability(delivered: text, read: read, strategy: strategy)
        let sameSelection = editability == .editable
        let bounds = sameSelection ? read?.range.flatMap { range in
            focused.flatMap { operations.selectionBounds(of: $0.element, range: range, primaryScreenHeight: primaryScreenHeight) }
        } : nil
        // Formatting is read where the selection is known; otherwise it cannot be checked.
        let formatting: FormattingState = if sameSelection, let range = read?.range, let element = focused?.element {
            operations.formattingState(of: element, range: range)
        } else {
            .unknown
        }
        return .success(Capture(
            text: text, app: app, element: sameSelection ? focused?.element : nil, range: sameSelection ? read?.range : nil,
            editability: editability, formatting: formatting, bounds: bounds, method: .accessibility))
    }

    nonisolated static func editability(delivered: String, read: SelectionOperations.SelectionRead?, strategy: AppStrategy) -> Editability {
        if strategy.readOnlyOnly || read?.isTerminalHelper == true { return .readOnlyOnly }
        guard let read, let text = read.text, text == delivered else { return .uncertain }
        return read.selectedTextSettable == true ? .editable : .uncertain
    }
}
