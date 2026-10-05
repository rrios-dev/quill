// Asks macOS for the NaturalLanguage name-tagging models the output guards use (G3 reads
// names with NLTagger's `.nameType`), in Quill's languages. A Mac in daily use has them; a
// fresh machine or a CI runner may not, and then the tagger finds no names and the guard
// cases that drop one fail. Prints the result per language; exits non-zero if any request
// fails.
//
//   swift Scripts/request-language-assets.swift
import Foundation
import NaturalLanguage

let languages: [NLLanguage] = [.spanish, .english]
var failed = false
for language in languages {
    let semaphore = DispatchSemaphore(value: 0)
    NLTagger.requestAssets(for: language, tagScheme: .nameType) { result, error in
        switch result {
        case .available: print("✓ \(language.rawValue): name tagging available")
        case .notAvailable:
            print("✗ \(language.rawValue): not available\(error.map { " — \($0.localizedDescription)" } ?? "")")
            failed = true
        case .error:
            print("✗ \(language.rawValue): \(error?.localizedDescription ?? "error")")
            failed = true
        @unknown default:
            print("✗ \(language.rawValue): unknown result")
            failed = true
        }
        semaphore.signal()
    }
    semaphore.wait()
}
exit(failed ? 1 : 0)
