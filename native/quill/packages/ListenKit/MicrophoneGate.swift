import Foundation

/// Whether the user's own voice may be transcribed right now.
///
/// Muting the microphone in Teams does not close it: the app keeps recording to warn
/// "you are muted" and simply stops sending. Quill opened its own capture of the same
/// microphone, so users muted in a call still found what they said in the transcript
/// (reported 2026-10-30). What the meeting heard is what Quill writes down: "me" is
/// transcribed only while every source that can tell says the microphone is live.
///
/// Three sources, any of which can mute (J-10):
/// - **the app holds no microphone** (Core Audio: none of its processes records input);
/// - **the app's mute control** says muted (read through Accessibility where the app
///   exposes one; `nil` when it cannot be read);
/// - **the user's own switch** in the live panel, for apps whose state Quill cannot read.
///
/// Thread-safe: the capture thread asks, the main thread and the session's watchdog tell.
public final class MicrophoneGate: @unchecked Sendable {
    public enum Reason: String, Sendable, Equatable {
        /// The meeting app is not recording from any microphone.
        case appReleasedMicrophone
        /// The meeting app's own mute control says muted.
        case mutedInApp
        /// The user muted Quill's copy of the microphone.
        case mutedInQuill
    }

    private let lock = NSLock()
    private var appHoldsMicrophone: Bool?
    private var appControlMuted: Bool?
    private var userMuted = false
    private var onChange: (@Sendable (Reason?) -> Void)?

    public init() {}

    /// Called with the new reason whenever the decision changes, on the caller's thread.
    public func observe(_ onChange: @escaping @Sendable (Reason?) -> Void) {
        lock.withLock { self.onChange = onChange }
    }

    /// Why the voice is not transcribed now, or nil when it is.
    public var mutedReason: Reason? {
        lock.withLock { reason }
    }

    public var isMuted: Bool { mutedReason != nil }

    /// What the app's mute control says: `true` muted, `false` live, `nil` unreadable.
    public var appControl: Bool? { lock.withLock { appControlMuted } }

    public var isUserMuted: Bool { lock.withLock { userMuted } }

    public func setAppHoldsMicrophone(_ holds: Bool?) { update { $0.appHoldsMicrophone = holds } }
    public func setAppControlMuted(_ muted: Bool?) { update { $0.appControlMuted = muted } }
    public func setUserMuted(_ muted: Bool) { update { $0.userMuted = muted } }

    /// Under the lock.
    private var reason: Reason? {
        if userMuted { return .mutedInQuill }
        if appControlMuted == true { return .mutedInApp }
        if appHoldsMicrophone == false { return .appReleasedMicrophone }
        return nil
    }

    private func update(_ change: (MicrophoneGate) -> Void) {
        let (before, after, callback) = lock.withLock { () -> (Reason?, Reason?, (@Sendable (Reason?) -> Void)?) in
            let before = reason
            change(self)
            return (before, reason, onChange)
        }
        if before != after { callback?(after) }
    }
}

/// Reads a meeting app's microphone control by what it says it will do.
///
/// A mute button is labelled with its action, not its state: "Silenciar" while the
/// microphone is live, "Reactivar audio" while it is muted. Teams, Zoom and Meet do the
/// same in Spanish and English, each with its own words, so the label is matched against
/// both families; anything else is not a microphone control.
public enum MuteLabel {
    public enum State: Equatable, Sendable { case live, muted }

    /// Label fragments in the order they are tried: the more specific first, because
    /// "unmute" contains "mute" and "desactivar micro" contains "activar micro".
    static let fragments: [(String, State)] = [
        ("unmute", .muted), ("dejar de silenciar", .muted), ("quitar silencio", .muted),
        ("desactivar micro", .live), ("desactivar el micro", .live), ("desactivar audio", .live),
        ("desactivar el audio", .live), ("desactivar sonido", .live),
        ("turn on microphone", .muted), ("turn on mic", .muted), ("activar micro", .muted),
        ("activar el micro", .muted), ("activar audio", .muted), ("activar el audio", .muted),
        ("activar sonido", .muted), ("reactivar", .muted),
        ("turn off microphone", .live), ("turn off mic", .live), ("mute", .live), ("silenciar", .live),
    ]
    /// Mute controls that are not the user's own microphone.
    static let excluded = [
        "mute all", "silenciar a todos", "silenciar todo", "notification", "notificacion",
        "speaker", "altavoz", "chat", "camera", "camara", "video", "participant", "participante",
    ]

    /// The microphone's state implied by a control's label, or nil if it is not one.
    public static func state(of label: String) -> State? {
        let folded = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !excluded.contains(where: folded.contains) else { return nil }
        return fragments.first { folded.contains($0.0) }?.1
    }
}
