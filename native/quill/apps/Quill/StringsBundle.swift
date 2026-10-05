import Foundation
import QuillSupport

extension Bundle {
    /// The app's strings, resolved inside the packaged app first (ARCHITECTURE §8).
    static let localized = ResourceBundle.resolve("Quill_Quill", fallback: .module)
}
