import Foundation

/// Environment switches for reviewing the app without a person in front of it
/// (ARCHITECTURE §3.6), in the manner of Ámbar's `ReviewHooks`.
///
/// They are read **only in debug builds**. A release binary must not carry hidden modes
/// that anyone with access to the environment can turn on: redirecting where data is
/// stored or silencing permission prompts are behaviours the user can neither see nor
/// switch off. In release builds every hook reads as unset, so call sites need no
/// `#if DEBUG` of their own.
enum DebugHooks {
    /// `QUILL_DATA_DIR=<path>` — use this directory instead of Application Support.
    static var dataDirectory: String? { value("QUILL_DATA_DIR") }

    /// `QUILL_TREAT_LOOPBACK_AS_REMOTE=1` — a loopback custom server goes through the
    /// hosted paths (consent, waiting to start, the cost estimate), so
    /// `Scripts/mock-chat-server.py` exercises them without keys (PLAN P3-T3).
    static var treatsLoopbackAsRemote: Bool { value("QUILL_TREAT_LOOPBACK_AS_REMOTE") != nil }

    /// `QUILL_DUMP_A11Y=1` — open every surface in turn, print its accessibility tree and
    /// quit (`Scripts/check-accessibility.sh`, PLAN P5-T3).
    static var dumpsAccessibility: Bool { value("QUILL_DUMP_A11Y") != nil }

    /// `QUILL_SNAPSHOT_PICKER=1` — show the picker in each of its states for two seconds,
    /// printing `SNAP <state> <window number>` so `screencapture -l` can photograph it,
    /// then quit (the picker's design review, `docs/initiatives/quill/qa/`).
    static var snapshotsPicker: Bool { value("QUILL_SNAPSHOT_PICKER") != nil }

    /// `QUILL_LOG_HOSTS=1` — log the host of every request a provider makes (P5-T5).
    static var logsHosts: Bool { value("QUILL_LOG_HOSTS") != nil }

    /// `QUILL_SUPPRESS_PROMPTS=1` — never ask the system for a permission prompt.
    static var suppressesPrompts: Bool { value("QUILL_SUPPRESS_PROMPTS") != nil }

    static func value(
        _ key: String,
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        #if DEBUG
        environment[key]
        #else
        nil
        #endif
    }
}
