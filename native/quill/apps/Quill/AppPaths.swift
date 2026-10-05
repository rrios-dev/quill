import Foundation

/// Where Quill keeps its files (ARCHITECTURE §4.2).
enum AppPaths {
    /// The bundle id until the product name is final (README Q1). Builds made with
    /// `make-app.sh --bundle-id` carry their own in `Info.plist`, read at run time.
    static let defaultBundleIdentifier = "dev.rrios.quill"

    /// `~/Library/Application Support/<bundle id>/`, or the debug hook's directory.
    ///
    /// Pure, so tests can check the resolution without touching the real folder.
    static func dataDirectory(
        bundleIdentifier: String?,
        applicationSupport: URL,
        overrideDirectory: String?
    ) -> URL {
        if let overrideDirectory, !overrideDirectory.isEmpty {
            return URL(fileURLWithPath: overrideDirectory, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(
            bundleIdentifier ?? defaultBundleIdentifier,
            isDirectory: true
        )
    }

    /// The app's Keychain service (ARCHITECTURE §4.2): fixed, never renamed with the
    /// product. A debug build whose bundle id extends the default one — the walkthrough
    /// build, `<default>.<suffix>` — gets `quill.providers.<suffix>`, so it never reads,
    /// deletes or prompts for another build's items.
    static func keychainService(bundleIdentifier: String?) -> String {
        let base = "quill.providers"
        guard let bundleIdentifier, bundleIdentifier.hasPrefix(defaultBundleIdentifier + ".") else { return base }
        return base + "." + bundleIdentifier.dropFirst(defaultBundleIdentifier.count + 1)
    }

    /// The data directory of this process.
    static var current: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dataDirectory(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            applicationSupport: applicationSupport,
            overrideDirectory: DebugHooks.dataDirectory
        )
    }
}
