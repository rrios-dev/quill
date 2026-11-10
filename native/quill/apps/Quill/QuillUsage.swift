import AppCore
import AppKit
import Foundation

/// Quill's side of the usage statistics (J-11): where they go, which counts exist, and
/// the one question that turns them on.
enum QuillUsage {
    /// `services/usage` on genesis, in the EU.
    static let endpoint = URL(string: "https://usage.rrios.dev/v1/usage")!

    /// Every count Quill may send. A name not here is never kept (`UsageReport.count`).
    static let counts: Set<String> = [
        "launches", "rewrites", "meetings", "meeting_minutes", "syntheses", "corrections",
        "voices_recognised", "voices_split", "microphone_muted_in_quill",
        // EFFICIENCY.md E7, E8.
        "meetings_started_by_agent", "dictations",
        "provider_apple", "provider_openrouter", "provider_openai", "provider_vercel", "provider_custom",
    ]

    /// The count for a provider used, by its id.
    static func provider(_ id: String) -> String {
        switch id {
        case "apple.on-device": "provider_apple"
        case "openrouter": "provider_openrouter"
        case "openai": "provider_openai"
        case "vercel-ai-gateway": "provider_vercel"
        default: "provider_custom"
        }
    }

    /// Asked once, never again whatever the answer: the switch in Settings changes it. A yes is a click,
    /// never a stray Return (AppCore's `ConsentAlert`, shared-control S8 fix round X1).
    @MainActor
    static func ask(_ report: UsageReport) {
        report.setConsent(ConsentAlert.ask(
            title: PickerCopy.string("usage.ask.title"), message: PickerCopy.string("usage.ask.body"),
            yes: PickerCopy.string("usage.ask.yes"), no: PickerCopy.string("usage.ask.no")))
    }
}
