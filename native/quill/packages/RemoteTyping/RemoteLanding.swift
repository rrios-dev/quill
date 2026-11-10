import Foundation

/// Where a text Quill is about to put into the focused app lands (shared-control S6 R2).
///
/// At the moment the text is ready, the keyboard's sharing app is asked where the keyboard
/// is — never earlier, never cached. On another computer, the text is typed there. Anywhere
/// else (no sharing app, the keyboard on this Mac, a refusal) the caller inserts it on this
/// Mac as it always did, so the text is never dropped. A refusal comes back once to be said;
/// the same refusal again is not repeated until something changes (a different refusal, or
/// a text that did reach the other computer).
public actor RemoteLanding {
    public enum Decision: Equatable, Sendable {
        /// Typed on the computer named here; the caller inserts nothing.
        case typed(computer: String)
        /// Insert on this Mac. `notice` is a refusal to say, or nil when there is nothing
        /// to say (no sharing app, the keyboard on this Mac, or a refusal already said).
        case local(notice: RemoteRefusal?)
    }

    private let keyboard: any RemoteKeyboard
    /// The refusal said last; nil once a text reached the other computer.
    private var lastSaid: RemoteRefusal?

    public init(keyboard: any RemoteKeyboard) {
        self.keyboard = keyboard
    }

    public func land(_ text: String) async -> Decision {
        switch await keyboard.status() {
        case .absent, .mac:
            return .local(notice: nil)
        case .refused(let refusal):
            return .local(notice: say(refusal))
        case .client(let computer):
            if let refusal = await keyboard.type(text, on: computer) {
                return .local(notice: say(refusal))
            }
            lastSaid = nil
            return .typed(computer: computer.name)
        }
    }

    // MARK: A text that comes from another computer (S6 R6)

    /// Where the shortcut's text comes from.
    public enum Source: Equatable, Sendable {
        /// This Mac: capture its selection as always (no sharing app, the keyboard here, or a
        /// sharing app that does not say where the keyboard is — then it is not elsewhere,
        /// since Quill's shortcut reached Quill).
        case mac
        /// The selection of the computer that has the keyboard.
        case client(RemoteComputer, text: String)
        /// The keyboard is on another computer and its selection cannot be used: say this,
        /// and do nothing else (never a capture on this Mac, whose selection is not the one
        /// the owner pointed at).
        case nothing(SelectionNotice)
    }

    /// Why the other computer's selection cannot be used.
    public enum SelectionNotice: Equatable, Sendable {
        case nothingSelected(computer: String)
        /// That computer cannot say what is selected.
        case unreadable(computer: String)
        case refused(RemoteRefusal)
    }

    /// Asked when the shortcut fires: on another computer, its selection is the text.
    public func source() async -> Source {
        guard case .client(let computer) = await keyboard.status() else { return .mac }
        switch await keyboard.selection(on: computer) {
        case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return .client(computer, text: text)
        case .text:
            return .nothing(.nothingSelected(computer: computer.name))
        case .unreadable:
            return .nothing(.unreadable(computer: computer.name))
        case .refused(let refusal):
            return .nothing(.refused(refusal))
        }
    }

    /// Types a text made from `computer`'s selection back on `computer`, and nowhere else:
    /// that selection, still active there, is what it replaces. nil when it was typed; else
    /// why not, to say every time (the text did not land where the owner expects it), never
    /// held back like `land(_:)`'s repeated refusals.
    public func land(_ text: String, on computer: RemoteComputer) async -> RemoteRefusal? {
        switch await keyboard.status() {
        case .client(let now) where now.id == computer.id:
            if let refusal = await keyboard.type(text, on: computer) { return refusal }
            lastSaid = nil
            return nil
        case .client, .mac:
            return .focusMoved(computer: computer.name)
        case .absent:
            return .noAnswer
        case .refused(let refusal):
            return refusal
        }
    }

    /// Keeps the keys on this Mac while a window of Quill needs them
    /// (`RemoteKeyboard.holdKeyboard`). Synchronous, so the last call made is the one that
    /// stands, whatever order the sharing app hears them in.
    public nonisolated func hold(_ hold: Bool) {
        keyboard.holdKeyboard(hold)
    }

    /// The refusal to say, or nil when it is the one said last.
    private func say(_ refusal: RemoteRefusal) -> RemoteRefusal? {
        guard refusal != lastSaid else { return nil }
        lastSaid = refusal
        return refusal
    }
}
