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

    @Test("preferences saved by 1.3.0, before Batuta was listed, offer Batuta's calls too")
    func batutaAdoptedFromOneThreeZero() {
        var preferences = MeetingPreferences()
        preferences.knownApps = Set(MeetingApp.known.map(\.id)).subtracting(["batuta"])
        preferences.offerApps = preferences.knownApps!.subtracting(["zoom"])
        preferences.adoptNewApps()
        #expect(preferences.offerApps.contains("batuta"))
        #expect(!preferences.offerApps.contains("zoom"))
    }

    @Test("Settings lists Batuta among the meeting apps, beside Teams and Zoom, not under the browsers")
    func batutaListed() {
        let listed = MeetingApp.known.filter { !$0.isBrowser }.map(\.id)
        #expect(listed.contains("batuta") && listed.contains("teams") && listed.contains("zoom"))
        #expect(MeetingPreferences().offerApps.contains("batuta"))
    }

    @Test("with only Claude Code connected, the synthesis moves off OpenRouter onto the plan")
    func usableModelPrefersConnected() {
        #expect(SynthesisModelChoice.usable(preferring: .fidelity, available: [.onDevice, .plan]) == .plan)
        #expect(SynthesisModelChoice.usable(preferring: .economy, available: Set(SynthesisModelChoice.allCases)) == .economy)
        #expect(SynthesisModelChoice.usable(preferring: .fidelity, available: []) == .fidelity)
    }

    @Test("the plan choice runs Claude Code's Sonnet and round-trips through the saved preference")
    func planChoice() {
        var preferences = MeetingPreferences()
        let selection = SynthesisModelChoice.plan.selection
        preferences.model = "\(selection.provider.rawValue):\(selection.model.rawValue)"
        #expect(preferences.model == "claude-code:sonnet")
        #expect(SynthesisModelChoice.matching(preferences.modelSelection) == .plan)
    }
}
