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

    /// `QUILL_LISTEN=<target>` — transcribe a process's audio for `QUILL_LISTEN_SECONDS`
    /// (default 30), write the transcript to `QUILL_LISTEN_REPORT` and quit (MEETINGS.md,
    /// spike S1). `<target>` is `pid:<n>`, `bundle:<id>[,<id>…]` or `list`, which prints
    /// the processes Core Audio sees. `QUILL_LISTEN_MIC=1` adds the microphone as "me";
    /// `QUILL_LISTEN_MUTE=1` silences the tapped process, for synthetic test audio.
    static var listenTarget: String? { value("QUILL_LISTEN") }

    /// `QUILL_SNAPSHOT_MEETINGS=<transcript.txt>` — seed a meeting from a transcript in
    /// `[hh:mm:ss] Name: text` lines (with `QUILL_SNAPSHOT_SYNTHESIS=<file.md>` and (fixtures: tools/QuillBench/data/synthesis/meeting-1.synthesis-*.md)
    /// `QUILL_SNAPSHOT_ANALYSIS=<file.md>` as its syntheses for the "work" and "analysis"
    /// focuses), open every meetings surface in turn and print `SNAP <surface> <window>`
    /// for `screencapture -l`, then quit. Run with an empty `QUILL_DATA_DIR`.
    static var snapshotsMeetings: String? { value("QUILL_SNAPSHOT_MEETINGS") }

    /// `QUILL_OPEN_MEETING=<uuid>` — open that meeting's window at launch, for checking a
    /// meeting surface by hand or with screen tools.
    static var openMeeting: UUID? { value("QUILL_OPEN_MEETING").flatMap(UUID.init(uuidString:)) }

    /// `QUILL_OPEN_MEETING_MOVES=<i>,<j>…` — with `QUILL_OPEN_MEETING`, give those sentences
    /// to someone else as "Said by… → Someone else" would: the first to a new voice, the
    /// rest to the same one.
    static var openMeetingMoves: [Int] {
        value("QUILL_OPEN_MEETING_MOVES")?.split(separator: ",").compactMap { Int($0) } ?? []
    }

    /// `QUILL_CHECK_UPDATES=<version>` — debug builds do not ask GitHub for updates unless
    /// this is set; the value stands for the running version ("1" keeps the bundle's), so
    /// an older one sees the published release as new. `QUILL_OPEN_SETTINGS=general` opens
    /// that Settings pane at launch.
    static var updateCheckVersion: String? { value("QUILL_CHECK_UPDATES") }
    static var openSettingsPane: String? { value("QUILL_OPEN_SETTINGS") }

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
