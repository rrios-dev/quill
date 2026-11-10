import Foundation

/// Where the keyboard is, as the app that shares it says (Batuta, `docs/local-api.md`).
public enum RemoteStatus: Equatable, Sendable {
    /// Nothing shares this Mac's keyboard: no such app is running, or this build cannot
    /// check who answers on its socket (an unsigned development build).
    case absent
    /// The keyboard is on this Mac.
    case mac
    /// The keyboard is on another computer, which text can be typed on.
    case client(RemoteComputer)
    /// The sharing app answered, but not with where the keyboard is.
    case refused(RemoteRefusal)
}

/// A computer the keyboard can be on: the sharing app's id for it and the name the owner gave it.
public struct RemoteComputer: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Why text could not go to the computer with the keyboard. Quill words each one itself;
/// the sharing app's own sentence is never shown (it is English, and not Quill's voice).
public enum RemoteRefusal: Equatable, Sendable {
    /// The sharing app's switch for other apps is off.
    case accessOff
    /// The sharing app turned Quill away (not its team, another user…).
    case refused
    /// Something listens on the sharing app's socket, but it is not that app: nothing was sent.
    case untrustedServer
    /// The sharing app did not answer in time, or answered something unreadable.
    case noAnswer
    /// The computer with the keyboard did not take the text (it cannot type, went offline or
    /// lost the keyboard a moment ago).
    case cannotType(computer: String)
    /// The keyboard left the computer named here (the one a text came from) before the text
    /// was ready: nothing was typed anywhere.
    case focusMoved(computer: String)
}

/// What the computer with the keyboard has selected (shared-control S6 R6).
public enum RemoteSelection: Equatable, Sendable {
    /// The selected text; empty when nothing is selected there.
    case text(String)
    /// The computer could not say what is selected (it cannot read selections, or the
    /// sharing app does not know the verb).
    case unreadable
    /// The sharing app answered, but not with the selection.
    case refused(RemoteRefusal)
}

/// A global shortcut, as the sharing app is told to keep it on this Mac: a macOS virtual key
/// code and its modifiers.
public struct RemoteChord: Equatable, Hashable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case command, option, control, shift
    }

    public var keyCode: Int
    public var modifiers: Set<Modifier>

    public init(keyCode: Int, modifiers: Set<Modifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Whether the sharing app keeps this Mac's shortcuts on the Mac while another computer has
/// the keyboard.
public enum RemoteReservation: Equatable, Sendable {
    /// No sharing app to ask, or nothing to keep.
    case none
    /// The shortcuts stay on this Mac wherever the keyboard is.
    case reserved
    /// The sharing app turned the shortcuts down: while another computer has the keyboard,
    /// they reach that computer instead.
    case refused(RemoteRefusal)
}

/// Working on the computer that has the keyboard, when that is not this Mac: typing there,
/// reading its selection, keeping this Mac's shortcuts and keys home. The port Quill's
/// session talks to; `BatutaKeyboard` is the live adapter, tests use a fake.
public protocol RemoteKeyboard: Sendable {
    /// Where the keyboard is now. Asked every time, never cached: the keyboard moves.
    func status() async -> RemoteStatus
    /// Types `text` on `computer` (from `status`), only if it still has the keyboard; nil
    /// when the sharing app took the text.
    func type(_ text: String, on computer: RemoteComputer) async -> RemoteRefusal?
    /// What `computer` (from `status`) has selected; `.refused(.focusMoved)` when the
    /// keyboard is no longer there.
    func selection(on computer: RemoteComputer) async -> RemoteSelection
    /// Keeps the keys on this Mac while `hold` is true (the pointer is not affected), so a
    /// window of this Mac can be typed in while another computer has the keyboard. Returns at
    /// once: the latest call wins, whatever order the sharing app hears them in.
    func holdKeyboard(_ hold: Bool)
    /// The shortcuts to keep on this Mac wherever the keyboard is, replacing the previous
    /// ones (empty releases them). Returns at once; kept across the sharing app's restarts.
    func reserve(_ chords: [RemoteChord])
    /// What became of the last `reserve`.
    var reservation: RemoteReservation { get }
}
