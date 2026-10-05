import os

/// The one logging entry point of every Quill target (ARCHITECTURE §6).
///
/// Ordinary messages describe what the app did — never what the user wrote. User text
/// goes only through `userText(_:_:)`, which compiles to nothing unless the build sets
/// `QUILL_LOG_USER_TEXT` (debug builds only), and even then logs it as private data.
/// Its format string carries the canary `QUILL-USERTEXT`, so a release binary can be
/// checked with `strings` for the absence of any user-text logging (PLAN P5-T5).
///
/// `ModelKit` does not use this: it stays dependency-free and logs nothing; its
/// callers log.
public struct QuillLog: Sendable {
    public static let subsystem = "dev.rrios.quill"

    private let logger: Logger

    public init(category: String) {
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Logs text that came from the user — a selection, a rewrite, a sample.
    ///
    /// A no-op in release builds: the call is kept so call sites need no `#if`, but its
    /// body, and the canary in its format string, exist only with `QUILL_LOG_USER_TEXT`.
    public func userText(_ context: String, _ text: String) {
        #if QUILL_LOG_USER_TEXT
        logger.debug("QUILL-USERTEXT \(context, privacy: .public): \(text, privacy: .private)")
        #endif
    }
}
