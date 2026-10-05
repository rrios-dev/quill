import Foundation
import ModelKit
import QuillSupport
import RewriteKit
import SelectionKit

/// The single mapping from every state the user can meet to its copy and, where there
/// is one, its action (ARCHITECTURE §5.1: error presentation, tradeoff copy).
///
/// Each mapping returns an `Entry` — a localization key with its arguments — rather
/// than a finished string, so `PresentationTests` can check every case against both
/// languages' tables. The switches are exhaustive: a new case does not compile until it
/// has copy.
enum Presentation {
    struct Entry: Equatable {
        var key: String
        var arguments: [String] = []
        var action: Action?

        /// The text in the app's current language.
        var text: String { text(in: .localized) }

        func text(in bundle: Bundle) -> String {
            let format = bundle.localizedString(forKey: key, value: nil, table: nil)
            return arguments.isEmpty ? format : String(format: format, arguments: arguments.map { $0 as CVarArg })
        }
    }

    enum Action: Equatable {
        case openProviderSettings
        case openAppleIntelligenceSettings
        case openAccessibilitySettings
        case openPasteSettings
        case openCaptureSettings
        case retry
    }

    // MARK: Provider errors

    static func providerError(_ code: ProviderError.Code) -> Entry {
        switch code {
        case .invalidRequest: Entry(key: "picker.failure.invalidRequest", action: .openProviderSettings)
        case .authentication: Entry(key: "picker.failure.authentication", action: .openProviderSettings)
        case .rateLimited: Entry(key: "picker.failure.rateLimited", action: .retry)
        case .contextExceeded: Entry(key: "picker.failure.contextExceeded")
        case .refused: Entry(key: "picker.refused")
        case .unavailable(let reason): unavailable(reason)
        case .network: Entry(key: "picker.failure.network", action: .retry)
        case .insecureConnection: Entry(key: "picker.failure.insecureConnection", action: .openProviderSettings)
        case .timeout: Entry(key: "picker.failure.timeout", action: .retry)
        case .server: Entry(key: "picker.failure.server", action: .retry)
        case .malformedResponse: Entry(key: "picker.failure.malformed", action: .retry)
        // Never shown as an error (ModelKit's contract), but it still has copy.
        case .cancelled: Entry(key: "picker.failure.cancelled")
        }
    }

    static func unavailable(_ reason: UnavailableReason) -> Entry {
        switch reason {
        case .missingCredential: Entry(key: "picker.failure.missingKey", action: .openProviderSettings)
        case .deviceNotEligible: Entry(key: "picker.failure.deviceNotEligible", action: .openProviderSettings)
        case .appleIntelligenceDisabled: Entry(key: "picker.failure.appleIntelligenceOff", action: .openAppleIntelligenceSettings)
        case .modelNotReady: Entry(key: "picker.failure.modelNotReady", action: .retry)
        case .unsupportedPlatform: Entry(key: "picker.failure.unsupportedPlatform", action: .openProviderSettings)
        }
    }

    static func failure(_ failure: Failure) -> Entry {
        switch failure {
        case .chooseModel(let profile):
            Entry(key: "picker.failure.chooseModel %@", arguments: [profile], action: .openProviderSettings)
        case .provider(let code):
            providerError(code)
        }
    }

    // MARK: Engine states

    /// A line per generation state — what VoiceOver hears and what the picker says when
    /// there is no text to show.
    static func engineState(_ state: GenerationState) -> Entry {
        switch state {
        case .idle: Entry(key: "state.idle")
        case .generating: Entry(key: "state.generating")
        case .ready(_, let flags): Entry(key: flags.isEmpty ? "state.ready" : "state.flagged")
        case .noChanges: Entry(key: "picker.noChanges")
        case .truncated: Entry(key: "picker.truncated")
        case .refused: Entry(key: "picker.refused")
        case .tooLong(let suggestion):
            suggestion.map { Entry(key: "picker.tooLong.suggestion %@", arguments: [$0.model.rawValue]) }
                ?? Entry(key: "picker.tooLong.shorten")
        case .failed(let code, _): providerError(code)
        case .cancelled: Entry(key: "state.cancelled")
        }
    }

    // MARK: Capture refusals

    static func refusal(_ refusal: CaptureRefusal) -> Entry {
        let product = QuillSupport.productName
        return switch refusal {
        case .notTrusted:
            Entry(key: "picker.refusal.notTrusted %@", arguments: [product], action: .openAccessibilitySettings)
        case .passwordField: Entry(key: "picker.refusal.passwordField %@", arguments: [product])
        case .noSelection: Entry(key: "picker.refusal.noSelection")
        case .copyNeedsAlwaysAllow: Entry(key: "picker.refusal.copyNeedsAlwaysAllow", action: .openPasteSettings)
        case .copyDisabled: Entry(key: "picker.refusal.copyDisabled", action: .openCaptureSettings)
        case .clipboardNotSaved: Entry(key: "picker.refusal.clipboardNotSaved")
        case .modifiersHeld: Entry(key: "picker.refusal.modifiersHeld")
        case .nothingCopied: Entry(key: "picker.refusal.nothingCopied")
        }
    }

    // MARK: Replace outcomes

    static func replaceOutcome(_ outcome: ReplaceOutcome) -> Entry {
        switch outcome {
        case .replaced: Entry(key: "toast.replaced")
        case .pasted: Entry(key: "toast.pasted")
        case .pastedUnconfirmed: Entry(key: "toast.pastedUnconfirmed")
        case .pastedClipboardHoldsRewrite: Entry(key: "toast.clipboardHoldsRewrite")
        case .copiedSelectionChanged: Entry(key: "toast.selectionChanged")
        case .copiedFocusNotReturned: Entry(key: "toast.focusNotReturned")
        case .copiedNotEditable: Entry(key: "toast.notEditable")
        case .clipboardBusy: Entry(key: "toast.clipboardBusy")
        }
    }

    // MARK: Providers: tradeoffs and recipients

    /// One sentence per advantage or drawback (PRODUCT F4 step 5, PROVIDERS §3).
    static func tradeoff(_ tradeoff: Tradeoff) -> Entry {
        switch tradeoff {
        case .free: Entry(key: "tradeoff.free")
        case .staysOnDevice: Entry(key: "tradeoff.staysOnDevice")
        case .worksOffline: Entry(key: "tradeoff.worksOffline")
        case .noAccountNeeded: Entry(key: "tradeoff.noAccountNeeded")
        case .unlimitedUse: Entry(key: "tradeoff.unlimitedUse")
        case .manyModels: Entry(key: "tradeoff.manyModels")
        case .singleRecipient: Entry(key: "tradeoff.singleRecipient")
        case .strongModels: Entry(key: "tradeoff.strongModels")
        case .paidPerUse: Entry(key: "tradeoff.paidPerUse")
        case .textLeavesDevice(let recipients):
            Entry(key: "tradeoff.textLeavesDevice %@", arguments: [recipientList(recipients)])
        case .requiresNetwork: Entry(key: "tradeoff.requiresNetwork")
        case .requiresAPIKey: Entry(key: "tradeoff.requiresAPIKey")
        case .smallContext(let tokens):
            Entry(key: "tradeoff.smallContext %@", arguments: [tokens.formatted()])
        case .smallModel: Entry(key: "tradeoff.smallModel")
        case .requiresAppleIntelligence: Entry(key: "tradeoff.requiresAppleIntelligence")
        case .limitedLanguages: Entry(key: "tradeoff.limitedLanguages")
        case .mayRefuseContent: Entry(key: "tradeoff.mayRefuseContent")
        case .dataPolicyVariesByModel: Entry(key: "tradeoff.dataPolicyVariesByModel")
        case .singleVendorCatalog: Entry(key: "tradeoff.singleVendorCatalog")
        case .localServerMayForward: Entry(key: "tradeoff.localServerMayForward")
        }
    }

    static func recipient(_ recipient: Recipient) -> Entry {
        switch recipient {
        // Brands and host names are not translated; the key only carries them.
        case .named(let name): Entry(key: "recipient.named %@", arguments: [name])
        case .routedInferenceProvider: Entry(key: "picker.recipient.routed")
        case .modelServingProvider: Entry(key: "picker.recipient.serving")
        case .host(let host): Entry(key: "recipient.host %@", arguments: [host])
        }
    }

    static func recipientList(_ recipients: [Recipient]) -> String {
        recipients.map { recipient($0).text }.formatted(.list(type: .and))
    }
}
