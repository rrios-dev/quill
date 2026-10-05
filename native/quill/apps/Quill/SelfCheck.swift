import Foundation
import RewriteKit

/// `--self-check` (ARCHITECTURE §8): loads every resource bundle the way the app does
/// and exits, **before** touching the data folder, the Keychain or the hot key. Honoured
/// in release builds too; `verify.sh` runs it against the release app with the build
/// folder renamed, so a bundle resolved from the machine that compiled it is caught.
enum SelfCheck {
    static let argument = "--self-check"

    /// Prints one line per check and returns the process exit status.
    static func run() -> Int32 {
        let resources = Bundle.main.resourceURL
        var problems: [String] = []
        var checked: [String] = []

        func require(_ name: String, at url: URL) {
            if let resources, isInside(url, resources) {
                checked.append(name)
            } else {
                problems.append("\(name) resolved outside the app's Resources: \(url.path)")
            }
        }

        require("Quill_Quill", at: Bundle.localized.bundleURL)
        if Bundle.localized.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                 forLocalization: "en") == nil {
            problems.append("Quill_Quill has no strings")
        }
        do {
            require("Quill_RewriteKit", at: try RewriteKitSelfCheck.run())
        } catch {
            problems.append("RewriteKit resources: \(error)")
        }
        problems += bundleProblems(in: resources, required: ["Quill_Quill", "Quill_RewriteKit", "Ambar_AppCore"])

        for name in checked { print("self-check: \(name) ✓") }
        for problem in problems { print("self-check: ✗ \(problem)") }
        return problems.isEmpty ? 0 : 1
    }

    /// Every `*.bundle` in `resources` must load and carry resources; `required` must be
    /// among them.
    static func bundleProblems(in resources: URL?, required: [String]) -> [String] {
        guard let resources else { return ["the app has no Resources directory"] }
        let entries = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        let bundles = entries.filter { $0.pathExtension == "bundle" }
        var problems: [String] = []
        for name in required where !bundles.contains(where: { $0.deletingPathExtension().lastPathComponent == name }) {
            problems.append("\(name).bundle is missing")
        }
        for url in bundles {
            guard let bundle = Bundle(url: url), let path = bundle.resourcePath,
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: path), !contents.isEmpty
            else {
                problems.append("\(url.lastPathComponent) does not load or is empty")
                continue
            }
        }
        return problems
    }

    static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return child.hasPrefix(parent + "/")
    }
}
