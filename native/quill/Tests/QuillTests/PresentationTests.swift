import Foundation
import ModelKit
import RewriteKit
import SelectionKit
import Testing

@testable import Quill

/// Every case the user can meet has copy in both MVP languages, with the right number
/// of arguments, and an action where one is due (PLAN P3-T7).
///
/// The case lists below are kept honest by the exhaustive switches beside them: adding
/// a case to any of these enums fails to compile here until it is listed.
@Suite("Presentation mapping")
struct PresentationTests {
    // MARK: Every case

    static let reasons: [UnavailableReason] = [
        .missingCredential, .deviceNotEligible, .appleIntelligenceDisabled, .modelNotReady, .unsupportedPlatform,
    ]
    static func listed(_ reason: UnavailableReason) {
        switch reason {
        case .missingCredential, .deviceNotEligible, .appleIntelligenceDisabled, .modelNotReady, .unsupportedPlatform: break
        }
    }

    static let codes: [ProviderError.Code] = [
        .invalidRequest, .authentication, .rateLimited(retryAfter: nil), .rateLimited(retryAfter: .seconds(5)),
        .contextExceeded, .refused, .network, .insecureConnection, .timeout, .server, .malformedResponse, .cancelled,
    ] + reasons.map(ProviderError.Code.unavailable)
    static func listed(_ code: ProviderError.Code) {
        switch code {
        case .invalidRequest, .authentication, .rateLimited, .contextExceeded, .refused, .unavailable, .network,
             .insecureConnection, .timeout, .server, .malformedResponse, .cancelled: break
        }
    }

    static let states: [GenerationState] = [
        .idle, .generating(partial: "x"), .ready(text: "x", flags: []), .ready(text: "x", flags: [.addedGreeting]),
        .noChanges, .truncated(partial: "x"), .refused, .tooLong(suggestion: nil),
        .tooLong(suggestion: ModelSelection(provider: "apple.on-device", model: "system")), .cancelled,
    ] + codes.map { .failed($0, partial: "") }
    static func listed(_ state: GenerationState) {
        switch state {
        case .idle, .generating, .ready, .noChanges, .truncated, .refused, .tooLong, .failed, .cancelled: break
        }
    }

    static let refusals: [CaptureRefusal] = [
        .notTrusted, .passwordField, .noSelection, .copyNeedsAlwaysAllow, .copyDisabled, .clipboardNotSaved,
        .modifiersHeld, .nothingCopied,
    ]
    static func listed(_ refusal: CaptureRefusal) {
        switch refusal {
        case .notTrusted, .passwordField, .noSelection, .copyNeedsAlwaysAllow, .copyDisabled, .clipboardNotSaved,
             .modifiersHeld, .nothingCopied: break
        }
    }

    static let outcomes: [ReplaceOutcome] = [
        .replaced, .pasted, .pastedUnconfirmed, .pastedClipboardHoldsRewrite, .copiedSelectionChanged,
        .copiedFocusNotReturned, .copiedNotEditable, .clipboardBusy,
    ]
    static func listed(_ outcome: ReplaceOutcome) {
        switch outcome {
        case .replaced, .pasted, .pastedUnconfirmed, .pastedClipboardHoldsRewrite, .copiedSelectionChanged,
             .copiedFocusNotReturned, .copiedNotEditable, .clipboardBusy: break
        }
    }

    static let recipients: [Recipient] = [.named("OpenRouter"), .routedInferenceProvider, .modelServingProvider, .host("gateway.example")]
    static func listed(_ recipient: Recipient) {
        switch recipient {
        case .named, .routedInferenceProvider, .modelServingProvider, .host: break
        }
    }

    static let tradeoffs: [Tradeoff] = [
        .free, .staysOnDevice, .worksOffline, .noAccountNeeded, .unlimitedUse, .manyModels, .singleRecipient,
        .strongModels, .paidPerUse, .textLeavesDevice(recipients: recipients), .requiresNetwork, .requiresAPIKey,
        .smallContext(tokens: 4_096), .smallModel, .requiresAppleIntelligence, .limitedLanguages, .mayRefuseContent,
        .dataPolicyVariesByModel, .singleVendorCatalog, .localServerMayForward,
    ]
    static func listed(_ tradeoff: Tradeoff) {
        switch tradeoff {
        case .free, .staysOnDevice, .worksOffline, .noAccountNeeded, .unlimitedUse, .manyModels, .singleRecipient,
             .strongModels, .paidPerUse, .textLeavesDevice, .requiresNetwork, .requiresAPIKey, .smallContext, .smallModel,
             .requiresAppleIntelligence, .limitedLanguages, .mayRefuseContent, .dataPolicyVariesByModel,
             .singleVendorCatalog, .localServerMayForward: break
        }
    }

    static var entries: [(String, Presentation.Entry)] {
        codes.map { ("code \($0)", Presentation.providerError($0)) }
            + states.map { ("state \($0)", Presentation.engineState($0)) }
            + refusals.map { ("refusal \($0)", Presentation.refusal($0)) }
            + outcomes.map { ("outcome \($0)", Presentation.replaceOutcome($0)) }
            + recipients.map { ("recipient \($0)", Presentation.recipient($0)) }
            + tradeoffs.map { ("tradeoff \($0)", Presentation.tradeoff($0)) }
            + [("chooseModel", Presentation.failure(.chooseModel(profile: "Work")))]
    }

    // MARK: Tables

    static func table(_ language: String) throws -> [String: String] {
        let path = try #require(Bundle.localized.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                                      forLocalization: language))
        return try #require(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    static func placeholders(_ format: String) -> Int {
        format.components(separatedBy: "%@").count - 1 + format.components(separatedBy: "%lld").count - 1
    }

    @Test("every case has copy in Spanish and English, with matching arguments", arguments: ["es", "en"])
    func copy(_ language: String) throws {
        let table = try Self.table(language)
        for (name, entry) in Self.entries {
            let format = try #require(table[entry.key], "\(name): no \(language) copy for \(entry.key)")
            #expect(!format.isEmpty, "\(name)")
            #expect(Self.placeholders(format) == entry.arguments.count, "\(name): \(entry.key) in \(language)")
        }
    }

    @Test("the two languages say different things, except where a brand or host passes through")
    func translated() throws {
        let spanish = try Self.table("es")
        let english = try Self.table("en")
        let passThrough: Set<String> = ["recipient.named %@", "recipient.host %@"]
        for (name, entry) in Self.entries where !passThrough.contains(entry.key) {
            #expect(spanish[entry.key] != english[entry.key], "\(name): \(entry.key) is not translated")
        }
    }

    // MARK: Actions

    @Test("what can be fixed in Settings opens it; what can be retried retries")
    func actions() {
        #expect(Presentation.providerError(.authentication).action == .openProviderSettings)
        #expect(Presentation.providerError(.unavailable(.missingCredential)).action == .openProviderSettings)
        #expect(Presentation.providerError(.unavailable(.appleIntelligenceDisabled)).action == .openAppleIntelligenceSettings)
        #expect(Presentation.failure(.chooseModel(profile: "Work")).action == .openProviderSettings)
        #expect(Presentation.providerError(.insecureConnection).action == .openProviderSettings)
        for code in Self.codes where ProviderError(code, "").isRetriable {
            #expect(Presentation.providerError(code).action == .retry, "\(code)")
        }
        #expect(Presentation.refusal(.notTrusted).action == .openAccessibilitySettings)
        #expect(Presentation.refusal(.copyNeedsAlwaysAllow).action == .openPasteSettings)
        #expect(Presentation.refusal(.copyDisabled).action == .openCaptureSettings)
        for outcome in Self.outcomes { #expect(Presentation.replaceOutcome(outcome).action == nil, "\(outcome)") }
    }

    @Test("arguments are filled in and nothing user-facing shows a raw key")
    func rendered() {
        let text = Presentation.tradeoff(.textLeavesDevice(recipients: [.named("OpenRouter"), .routedInferenceProvider])).text
        #expect(text.contains("OpenRouter"))
        #expect(!text.contains("%@"))
        for (name, entry) in Self.entries { #expect(entry.text != entry.key, "\(name)") }
    }
}
