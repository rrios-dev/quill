import Foundation
import Testing

@testable import Quill

/// Every UI string exists in both MVP languages (README D-12) until the full
/// localization check arrives (PLAN P5-T2).
@Suite("Localization parity")
struct LocalizationParityTests {
    private func keys(_ language: String) throws -> Set<String> {
        let path = try #require(
            Bundle.localized.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                  forLocalization: language),
            "no Localizable.strings for \(language)"
        )
        let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        return Set(table.keys)
    }

    @Test("Spanish and English define the same keys")
    func sameKeys() throws {
        let spanish = try keys("es")
        let english = try keys("en")
        #expect(!spanish.isEmpty)
        #expect(spanish == english, "only in es: \(spanish.subtracting(english)); only in en: \(english.subtracting(spanish))")
    }
}
