import Foundation
import ListenKit

/// An app meetings happen in, recognised by bundle identifier prefix so its helper
/// processes count too (Teams and browsers play and record from helpers).
public struct MeetingApp: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var bundlePrefixes: [String]
    /// A browser: the microphone may be a meeting (Meet) or anything else, so the offer
    /// names the browser, not a meeting service.
    public var isBrowser: Bool

    public init(id: String, name: String, bundlePrefixes: [String], isBrowser: Bool = false) {
        self.id = id
        self.name = name
        self.bundlePrefixes = bundlePrefixes
        self.isBrowser = isBrowser
    }

    public func matches(_ bundleID: String) -> Bool {
        bundlePrefixes.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }
}

extension MeetingApp {
    public static let known: [MeetingApp] = [
        MeetingApp(id: "teams", name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
        MeetingApp(id: "zoom", name: "Zoom", bundlePrefixes: ["us.zoom.xos"]),
        MeetingApp(id: "webex", name: "Webex", bundlePrefixes: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]),
        MeetingApp(id: "slack", name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"]),
        MeetingApp(id: "facetime", name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime"]),
        MeetingApp(id: "goto", name: "GoTo Meeting", bundlePrefixes: ["com.logmein.GoToMeeting", "com.logmein.goto"]),
        MeetingApp(id: "gather", name: "Gather", bundlePrefixes: ["com.gather.GatherV2", "com.gather.Gather"]),
        MeetingApp(id: "discord", name: "Discord", bundlePrefixes: ["com.hnc.Discord"]),
        MeetingApp(id: "whatsapp", name: "WhatsApp", bundlePrefixes: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        MeetingApp(id: "telegram", name: "Telegram", bundlePrefixes: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        MeetingApp(id: "signal", name: "Signal", bundlePrefixes: ["org.whispersystems.signal-desktop"]),
        MeetingApp(id: "brave", name: "Brave", bundlePrefixes: ["com.brave.Browser"], isBrowser: true),
        MeetingApp(id: "chrome", name: "Google Chrome", bundlePrefixes: ["com.google.Chrome"], isBrowser: true),
        // WebKit's helpers play and record for every WebKit browser (Orion, Safari
        // Technology Preview too), so those show up under Safari's name.
        MeetingApp(id: "safari", name: "Safari", bundlePrefixes: ["com.apple.Safari", "com.apple.WebKit"], isBrowser: true),
        MeetingApp(id: "arc", name: "Arc", bundlePrefixes: ["company.thebrowser.Browser"], isBrowser: true),
        MeetingApp(id: "dia", name: "Dia", bundlePrefixes: ["company.thebrowser.dia"], isBrowser: true),
        MeetingApp(id: "edge", name: "Microsoft Edge", bundlePrefixes: ["com.microsoft.edgemac"], isBrowser: true),
        MeetingApp(id: "firefox", name: "Firefox", bundlePrefixes: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"], isBrowser: true),
        MeetingApp(id: "zen", name: "Zen", bundlePrefixes: ["app.zen-browser.zen"], isBrowser: true),
        MeetingApp(id: "opera", name: "Opera", bundlePrefixes: ["com.operasoftware.Opera", "com.operasoftware.OperaGX"], isBrowser: true),
        MeetingApp(id: "vivaldi", name: "Vivaldi", bundlePrefixes: ["com.vivaldi.Vivaldi"], isBrowser: true),
        MeetingApp(id: "chromium", name: "Chromium", bundlePrefixes: ["org.chromium.Chromium"], isBrowser: true),
        MeetingApp(id: "comet", name: "Comet", bundlePrefixes: ["ai.perplexity.comet"], isBrowser: true),
    ]

    /// The ids `known` had in Quill 1.1.0, before it learnt the rest: preferences saved
    /// then list only these, so the apps added since are switched on for them on load.
    public static let knownIn1_1_0: Set<String> = [
        "teams", "zoom", "webex", "slack", "facetime", "brave", "chrome", "safari", "arc", "edge", "firefox",
    ]

    /// One of `known`, rather than an app picked up from the microphone (`unlisted`).
    public var isListed: Bool { Self.known.contains { $0.id == id } }

    /// An app that is not in `known`, recognised only because it has the microphone open:
    /// Quill cannot tell whether it is a meeting, so it asks as it does for browsers.
    public static func unlisted(bundleID: String, name: String) -> MeetingApp {
        MeetingApp(id: "app:" + bundleID, name: name, bundlePrefixes: [bundleID])
    }

    /// The app a process belongs to: helpers carry the app's identifier followed by
    /// `.helper…` (`com.hnc.Discord.helper.Renderer` → `com.hnc.Discord`).
    public static func owningBundleID(of bundleID: String) -> String {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let helper = parts.firstIndex(where: { $0.lowercased().hasPrefix("helper") }), helper > 1 else { return bundleID }
        return parts[..<helper].joined(separator: ".")
    }

    /// The apps outside `known` that have the microphone open, as bundle identifiers of
    /// the app (not its helper), the ones also playing audio first: a call plays and
    /// records, a dictation app only records. The system's own processes and Quill's
    /// family never count.
    public static func unlistedRecording(
        processes: [AudioProcess],
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        let ignoredPrefixes = ["com.apple.", "dev.rrios."]
        var playing: [String] = []
        var silent: [String] = []
        for process in processes where process.isRunningInput {
            guard let bundleID = process.bundleID, bundleID != ownBundleID,
                  !ignoredPrefixes.contains(where: bundleID.hasPrefix),
                  !known.contains(where: { $0.matches(bundleID) }) else { continue }
            let owner = owningBundleID(of: bundleID)
            let alsoPlays = processes.contains { other in
                other.isRunningOutput && other.bundleID.map { owningBundleID(of: $0) == owner } == true
            }
            if alsoPlays { if !playing.contains(owner) { playing.append(owner) } }
            else if !silent.contains(owner) { silent.append(owner) }
        }
        return playing + silent.filter { !playing.contains($0) }
    }

    /// Which of `apps` have a process using the microphone right now.
    ///
    /// Quill itself never counts, nor do processes without a bundle identifier.
    public static func recording(
        among apps: [MeetingApp],
        processes: [AudioProcess],
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [MeetingApp] {
        let ids = processes.filter(\.isRunningInput).compactMap(\.bundleID).filter { $0 != ownBundleID }
        return apps.filter { app in ids.contains(where: app.matches) }
    }
}
