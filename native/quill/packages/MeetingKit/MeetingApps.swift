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
        MeetingApp(id: "webex", name: "Webex", bundlePrefixes: ["Cisco-Systems.Spark"]),
        MeetingApp(id: "slack", name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"]),
        MeetingApp(id: "facetime", name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime"]),
        MeetingApp(id: "brave", name: "Brave", bundlePrefixes: ["com.brave.Browser"], isBrowser: true),
        MeetingApp(id: "chrome", name: "Google Chrome", bundlePrefixes: ["com.google.Chrome"], isBrowser: true),
        MeetingApp(id: "safari", name: "Safari", bundlePrefixes: ["com.apple.Safari", "com.apple.WebKit"], isBrowser: true),
        MeetingApp(id: "arc", name: "Arc", bundlePrefixes: ["company.thebrowser.Browser"], isBrowser: true),
        MeetingApp(id: "edge", name: "Microsoft Edge", bundlePrefixes: ["com.microsoft.edgemac"], isBrowser: true),
        MeetingApp(id: "firefox", name: "Firefox", bundlePrefixes: ["org.mozilla.firefox"], isBrowser: true),
    ]

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
