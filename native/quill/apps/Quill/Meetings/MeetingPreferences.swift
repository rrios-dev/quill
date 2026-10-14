import Foundation
import MeetingKit
import ModelKit
import SynthesisKit

/// Settings › Meetings (MEETINGS.md §6), in their own file next to the meetings: they
/// are about meetings, not about rewriting, and `QuillSettings` stays as it was.
struct MeetingPreferences: Codable, Equatable {
    /// Apps that trigger the offer when they open the microphone.
    var offerApps: Set<String> = Set(MeetingApp.known.map(\.id))
    /// Apps where listening starts without asking. Empty by default: the user opts in.
    var autoStartApps: Set<String> = []
    var includeMicrophone = true
    var localeIdentifier = "es_ES"
    var separateSpeakers = true
    var defaultFocusID = "work"
    /// "provider:model"; nil until the user picks one, then the recommended hosted model.
    var model: String?
    /// Owner's open decision Q3 — proposed default, adjustable.
    var retentionDays = 90
    /// Owner's open decision Q1 — the live panel shows by default and can be hidden.
    var showsLivePanel = true
    /// Translate what the others say when the meeting is in another language. Optional so
    /// preferences saved before it decode (a missing non-optional key would reset them
    /// all); nil means on.
    var translatesLive: Bool?
    /// The language translations go into: a BCP-47 code. Nil means the user's own
    /// language, the first one the system lists.
    var translationTarget: String?

    var translationLanguage: Locale.Language {
        Locale.Language(identifier: translationTarget ?? Locale.preferredLanguages.first ?? "es")
    }

    /// A meeting in `localeIdentifier` is in another language than the user's: worth
    /// translating.
    func needsTranslation(for localeIdentifier: String) -> Bool {
        (translatesLive ?? true)
            && Locale(identifier: localeIdentifier).language.languageCode != translationLanguage.languageCode
    }

    /// The languages a meeting can be transcribed in, offered in Settings and when a
    /// meeting starts.
    static let languages = ["es_ES", "es_MX", "en_US", "en_GB", "fr_FR", "de_DE", "it_IT", "pt_BR"]

    static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func load(from directory: URL) -> MeetingPreferences {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let decoded = try? JSONDecoder().decode(MeetingPreferences.self, from: data) else { return MeetingPreferences() }
        return decoded
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }

    static func url(in directory: URL) -> URL { directory.appendingPathComponent("meeting-preferences.json") }

    /// The model to synthesise with: the user's pick, else the first recommended hosted
    /// model, else on-device (marked as a draft wherever it appears).
    var modelSelection: ModelSelection {
        if let model, let colon = model.firstIndex(of: ":") {
            return ModelSelection(provider: ProviderID(rawValue: String(model[..<colon])),
                                  model: ModelID(rawValue: String(model[model.index(after: colon)...])))
        }
        return ModelSelection(provider: "openrouter", model: "anthropic/claude-sonnet-5.5")
    }
}

/// The models offered for synthesis, with what S3 measured about each (MEETINGS.md §4).
enum SynthesisModelChoice: CaseIterable, Identifiable {
    case fidelity, economy, onDevice

    var id: Self { self }

    var selection: ModelSelection {
        switch self {
        case .fidelity: ModelSelection(provider: "openrouter", model: "anthropic/claude-sonnet-5.5")
        case .economy: ModelSelection(provider: "openrouter", model: "openai/gpt-6-luna")
        case .onDevice: ModelSelection(provider: AppleOnDeviceProvider.providerID, model: "system")
        }
    }

    var name: String {
        switch self {
        case .fidelity: "Claude Sonnet 5.5"
        case .economy: "GPT-6 Luna"
        case .onDevice: MeetingCopy.t("synthesis.model.onDevice")
        }
    }

    /// Measured on a six-minute meeting (S3); scales with length.
    var costHint: String {
        switch self {
        case .fidelity: "≈ 0,02 $"
        case .economy: "≈ 0,001 $"
        case .onDevice: MeetingCopy.t("synthesis.model.draft")
        }
    }

    var isDraft: Bool { self == .onDevice }

    static func matching(_ selection: ModelSelection) -> SynthesisModelChoice? {
        allCases.first { $0.selection == selection }
    }
}

/// Meeting copy, from the app's string tables.
enum MeetingCopy {
    static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .localized)
    }

    /// The built-in roles and focuses in the interface's language (MeetingStore.BuiltInText).
    static var builtInText: MeetingStore.BuiltInText {
        typealias Entry = MeetingStore.BuiltInText.Entry
        return MeetingStore.BuiltInText(
            roles: [
                "product-owner": Entry(name: t("role.builtin.productOwner"), detail: t("role.builtin.productOwner.summary")),
                "tech-lead": Entry(name: t("role.builtin.techLead"), detail: t("role.builtin.techLead.summary")),
                "support": Entry(name: t("role.builtin.support"), detail: t("role.builtin.support.summary")),
                "engineer": Entry(name: t("role.builtin.engineer"), detail: t("role.builtin.engineer.summary")),
                "client": Entry(name: t("role.builtin.client"), detail: t("role.builtin.client.summary")),
                "vendor": Entry(name: t("role.builtin.vendor"), detail: t("role.builtin.vendor.summary")),
            ],
            focuses: [
                "work": Entry(name: t("focus.builtin.work"), detail: t("focus.builtin.work.objective")),
                "analysis": Entry(name: t("focus.builtin.analysis"), detail: t("focus.builtin.analysis.objective")),
                "brief": Entry(name: t("focus.builtin.brief"), detail: t("focus.builtin.brief.objective")),
            ]
        )
    }

    static func treatment(_ treatment: Treatment) -> String {
        switch treatment {
        case .decides: t("treatment.decides")
        case .influences: t("treatment.influences")
        case .context: t("treatment.context")
        case .request: t("treatment.request")
        case .minimal: t("treatment.minimal")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: max(seconds, 60)) ?? ""
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
