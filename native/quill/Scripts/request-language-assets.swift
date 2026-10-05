// Asks macOS for the NaturalLanguage name-tagging models the output guards use (G3 reads
// names with NLTagger's `.nameType`), in Quill's languages. A Mac in daily use has them; a
// fresh machine or a CI runner may not, and then the tagger finds no names and the guard
// cases that drop one fail. Prints the result per language and exits non-zero if any
// request fails or takes longer than five minutes.
//
//   swift Scripts/request-language-assets.swift
import Foundation
import NaturalLanguage

func request(_ language: NLLanguage) async -> Bool {
    do {
        let result = try await NLTagger.requestAssets(for: language, tagScheme: .nameType)
        switch result {
        case .available:
            print("✓ \(language.rawValue): name tagging available")
            return true
        case .notAvailable:
            print("✗ \(language.rawValue): not available")
        case .error:
            print("✗ \(language.rawValue): error")
        @unknown default:
            print("✗ \(language.rawValue): unknown result")
        }
    } catch {
        print("✗ \(language.rawValue): \(error.localizedDescription)")
    }
    return false
}

let ok = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        var ok = true
        for language in [NLLanguage.spanish, .english] where !(await request(language)) { ok = false }
        return ok
    }
    group.addTask {
        // Cancelled as soon as the requests finish; only a real timeout gets to print.
        guard (try? await Task.sleep(for: .seconds(300))) != nil else { return false }
        print("✗ timed out after five minutes")
        return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}
exit(ok ? 0 : 1)
