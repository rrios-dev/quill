import MeetingKit
import Testing

@testable import Quill

/// Preferences saved by an older Quill pick up the meeting apps added since.
@Suite("Meeting preferences")
struct MeetingPreferencesTests {
    private let added = Set(MeetingApp.known.map(\.id)).subtracting(MeetingApp.knownIn1_1_0)
    private let browsers = Set(MeetingApp.known.filter(\.isBrowser).map(\.id))

    @Test("1.1.0 preferences switch on the new apps and keep what the user switched off")
    func fromOneOneZero() {
        var preferences = MeetingPreferences()
        preferences.knownApps = nil
        preferences.offerApps = MeetingApp.knownIn1_1_0.subtracting(["zoom"])
        preferences.adoptNewApps()
        #expect(!preferences.offerApps.contains("zoom"))
        #expect(preferences.offerApps.isSuperset(of: added))
        #expect(preferences.knownApps == Set(MeetingApp.known.map(\.id)))
    }

    @Test("new browsers follow the browsers' switch")
    func browsersFollowTheSwitch() {
        var preferences = MeetingPreferences()
        preferences.knownApps = nil
        preferences.offerApps = MeetingApp.knownIn1_1_0.subtracting(browsers)
        preferences.adoptNewApps()
        #expect(preferences.offerApps.isDisjoint(with: browsers))
        #expect(preferences.offerApps.contains("discord"))
    }

    @Test("an app the user switched off stays off once known")
    func switchedOffStaysOff() {
        var preferences = MeetingPreferences()
        preferences.offerApps.remove("discord")
        preferences.adoptNewApps()
        #expect(!preferences.offerApps.contains("discord"))
    }
}
