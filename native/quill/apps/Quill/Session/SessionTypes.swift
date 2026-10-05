import CoreGraphics
import Foundation
import ModelKit
import RewriteKit
import SelectionKit

/// What the picker shows (PRODUCT §4.1). Wraps the engine's generation states with the
/// ones RewriteKit cannot know (ARCHITECTURE §2, "State ownership").
enum SessionState: Equatable {
    case idle
    case capturing
    case refusedCapture(CaptureRefusal)
    case awaitingConsent(ConsentNotice)
    case waitingToStart(StartNotice)
    case generating(partial: String)
    /// A result with no flag left to confirm.
    case ready(text: String)
    /// A result whose flags need ⌘Return before it can be applied.
    case flagged(text: String, flags: [GuardFlag])
    case noChanges
    case truncated(partial: String)
    case refused
    case failed(Failure, partial: String)
    case tooLong(model: ModelSelection, suggestion: ModelSelection?)
    case correcting(Correction)
    /// A timed-out clipboard read is still running: nothing may be written until it
    /// ends (ARCHITECTURE §3.4). `resume` is the state to return to.
    case waitingForClipboard(text: String, resume: Resume)
    case applying
    case applied(AppliedOutcome)
    /// The picker closed without applying.
    case closed

    enum Resume: Equatable {
        case ready
        case flagged([GuardFlag])
        case noChanges
    }

    var isTerminal: Bool {
        switch self {
        case .applied, .closed: true
        default: false
        }
    }
}

/// Why a rewrite failed.
enum Failure: Equatable {
    case provider(ProviderError.Code)
    /// No model resolves for the profile, or its pinned model's provider is unavailable:
    /// "Choose a model for <profile>" — never another provider in its place (README D-16).
    case chooseModel(profile: String)
}

/// The one-time notice before user text goes to a recipient (ARCHITECTURE §5.3, §6).
struct ConsentNotice: Equatable {
    var provider: ProviderID
    var providerName: String
    var recipients: [Recipient]
    /// First text to this hosted provider.
    var firstUseOfProvider: Bool
    /// The profile's user-authored examples or guidance go to a new recipient.
    var profileTextToNewRecipient: Bool
    /// Set when the text is also over the large-text threshold: consent and the
    /// large-text confirmation are one step (PRODUCT §4.1).
    var largeText: StartNotice?
}

/// What waiting to start shows: the word count and, when the price is published, an
/// estimated cost.
struct StartNotice: Equatable {
    enum Reason: Equatable {
        case largeText
        case services
    }

    var reason: Reason
    var words: Int
    var estimatedCost: Double?
}

/// ⌘E: the result being corrected (PRODUCT §4.1 Correcting).
struct Correction: Equatable {
    var text: String
    var saveAsExample: Bool
    /// Why "Save as example" is unavailable, if it is.
    var saveDisabledReason: SaveDisabledReason?
    /// A decision the save needs before it can complete.
    var pending: PendingSave?
    /// The state ⌘E came from; Esc goes back to it.
    var previous: PreviousState

    enum SaveDisabledReason: Equatable {
        /// Either text is over the 500-character example cap.
        case tooLong
    }

    enum PendingSave: Equatable {
        /// The profile already has 8 examples: which one to replace.
        case chooseReplacement([Example])
        /// The pair contains personal identifiers: neutral stand-ins, or save without
        /// the example.
        case personalData(Set<PersonalDataScreen.Kind>)
    }

    enum PreviousState: Equatable {
        case ready(String)
        case flagged(String, [GuardFlag])
        case noChanges
    }
}

/// How a session ended for the user (PRODUCT §4.1 Applied).
enum AppliedOutcome: Equatable {
    case replace(ReplaceOutcome)
    /// ⌘C, or Return on a target that cannot be pasted into.
    case copied
}

/// The picker's keys (PRODUCT §4.1 columns).
enum PickerKey: Equatable, CaseIterable {
    case returnKey, commandReturn, optionReturn, commandC
    /// 1–9: the profile at that position.
    case number(Int)
    case tab
    case commandE, d, r
    case escape
    /// The global shortcut pressed while the session is open.
    case shortcut

    static var allCases: [PickerKey] {
        [.returnKey, .commandReturn, .optionReturn, .commandC, .number(1), .tab, .commandE, .d, .r, .escape, .shortcut]
    }
}

/// Side effects the session asks of its window.
enum SessionEffect: Equatable {
    /// Show the picker (a direct apply that cannot apply opens it, with the reason).
    case showPicker
    case close
    /// "Rewritten with <profile> · ⌘Z to undo" after a direct apply, or the outcome's
    /// line after the picker closed (PRODUCT §4.1 Applied).
    case toast(AppliedOutcome, profile: String, direct: Bool)
    case openSettings(SettingsPane)
    case openAccessibilitySettings

    enum SettingsPane: Equatable {
        case providers
    }
}

/// Why a direct apply opened the picker instead (PRODUCT F2: the reason is visible).
enum DirectApplyDeclined: Equatable {
    case notReady
    case flagged
    case targetNotEditable
    /// The app's strategy does not paste, or ⌘Z was not verified there.
    case notUndoable
}

/// How a session started.
enum Trigger {
    /// The global shortcut over `app`. The session captures.
    case hotKey(app: AppIdentity, hotKeyCode: CGKeyCode?)
    /// The Services entry delivered the capture (PLAN P3-T6). Hosted rewrites wait for
    /// Return, so another process cannot spend the user's key unattended.
    case services(Capture)
}

/// Reading and replacing text, for the session. The live one wraps SelectionKit's
/// sequences (PLAN P3-T5); tests use a fake.
@MainActor
protocol SessionSelection: AnyObject {
    func capture(app: AppIdentity, hotKeyCode: CGKeyCode?) async -> Result<Capture, CaptureRefusal>
    /// Takes the pasteboard snapshot while the model generates (off the critical path).
    func prepareSnapshot() async
    func replace(_ text: String, capture: Capture, pasteAnyway: Bool) async -> ReplaceOutcome
    /// Copies `text`, kept off Universal Clipboard. False when a timed-out snapshot read
    /// is still running and nothing may be written.
    func copy(_ text: String) async -> Bool
    /// Returns when the timed-out read has ended.
    func clipboardReadFinished() async
    func strategy(for bundleIdentifier: String?) -> AppStrategy
}

/// Model facts the session needs beyond the registry: context sizes and prices from the
/// model lists, and the models the too-long suggestion may name.
protocol ModelCatalog: Sendable {
    func descriptor(for selection: ModelSelection) async -> ModelDescriptor?
    func alternatives() async -> [ModelCandidate]
}

/// Where "Save as example" lands (PLAN P4-T4 builds the store side).
@MainActor
protocol ExampleSink: AnyObject {
    /// Saves `example` into the profile, replacing `replacing` when given; returns the
    /// profile as stored.
    func save(_ example: Example, to profileID: UUID, replacing: UUID?) throws -> Profile
    /// The pair with its personal identifiers swapped for neutral stand-ins.
    func neutralized(_ example: Example) -> Example
}
