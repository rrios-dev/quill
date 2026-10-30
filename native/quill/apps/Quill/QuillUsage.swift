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
        "voices_recognised", "microphone_muted_in_quill",
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

    /// Asked once, never again whatever the answer: the switch in Settings changes it.
    @MainActor
    static func ask(_ report: UsageReport) {
        let alert = NSAlert()
        alert.messageText = PickerCopy.string("usage.ask.title")
        alert.informativeText = PickerCopy.string("usage.ask.body")
        alert.addButton(withTitle: PickerCopy.string("usage.ask.yes"))
        alert.addButton(withTitle: PickerCopy.string("usage.ask.no"))
        NSApplication.shared.activate()
        report.setConsent(alert.runModal() == .alertFirstButtonReturn)
    }
}
