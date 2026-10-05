import Foundation
import ModelKit
import QuillSupport
import RewriteKit
import SelectionKit

/// What the picker says for each state (PRODUCT §4.1). Errors, refusals, outcomes,
/// tradeoffs and recipients come from `Presentation`, the checked mapping; the picker's
/// own lines (flags, notes, hints) live here.
enum PickerCopy {
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .localized)
    }

    static func refusal(_ refusal: CaptureRefusal) -> String { Presentation.refusal(refusal).text }

    static func failure(_ failure: Failure) -> String { Presentation.failure(failure).text }

    static func flag(_ flag: GuardFlag) -> String {
        switch flag {
        case .uncertainPreamble: string("picker.flag.preamble")
        case .inventedPlaceholder(let found): string("picker.flag.placeholder \(found.joined(separator: ", "))")
        case .missingPreserved(_, let missing): string("picker.flag.missing \(missing.joined(separator: ", "))")
        case .lineBreaksChanged: string("picker.flag.lineBreaks")
        case .missingEmoji: string("picker.flag.emoji")
        case .languageChanged: string("picker.flag.language")
        case .lengthOutOfBand: string("picker.flag.length")
        case .addedGreeting: string("picker.flag.greeting")
        case .addedSignOff: string("picker.flag.signOff")
        case .exampleEcho: string("picker.flag.exampleEcho")
        case .formattingWillBeLost: string("picker.flag.formattingLost")
        case .formattingUnchecked: string("picker.flag.formattingUnchecked")
        case .addedFacts(let facts): string("picker.flag.addedFacts \(facts.joined(separator: ", "))")
        case .trailingCommentary: string("picker.flag.commentary")
        }
    }

    static func recipients(_ recipients: [Recipient]) -> String { Presentation.recipientList(recipients) }

    static func declined(_ reason: DirectApplyDeclined) -> String {
        switch reason {
        case .notReady: string("picker.direct.notReady")
        case .flagged: string("picker.direct.flagged")
        case .targetNotEditable: string("picker.direct.notEditable")
        case .notUndoable: string("picker.direct.notUndoable")
        }
    }

    static func cost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 0.01 ? 4 : 2)))
    }
}
