import Foundation

/// Finds a module's resource bundle inside the packaged app before trusting SwiftPM.
///
/// Older SwiftPM builds generated a `Bundle.module` accessor that looked only at the
/// app's root (`Bundle.main.bundleURL`) and at the absolute build path of the machine
/// that compiled it, then called `fatalError`. Resource bundles must live in
/// `Contents/Resources` — `codesign` rejects anything unsealed in the bundle root — so
/// that accessor worked on the developer's Mac and crashed on everyone else's (Ámbar's
/// `StringsBundle` exists because of it). Newer toolchains look in `resourceURL`
/// first, but nothing promises they keep doing so (ARCHITECTURE §8).
///
/// Every Quill module with resources declares, once:
///
///     extension Bundle {
///         static let localized = ResourceBundle.resolve("Quill_Quill", fallback: .module)
///     }
///
/// and passes `bundle: .localized` to every `String(localized:)`.
public enum ResourceBundle {
    /// The bundle named `<package>_<target>.bundle` in `searchDirectory`
    /// (the app's `Contents/Resources` by default), or `fallback` when there is none —
    /// development, tests and `swift run`, where SwiftPM's accessor resolves it.
    public static func resolve(
        _ name: String,
        in searchDirectory: URL? = Bundle.main.resourceURL,
        fallback: @autoclosure () -> Bundle
    ) -> Bundle {
        if let url = searchDirectory?.appendingPathComponent("\(name).bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return fallback()
    }
}
