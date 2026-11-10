import Foundation
import ListenKit
import Testing

@testable import MeetingKit

/// Which app is in a meeting, from what Core Audio reports (`MeetingApp`).
@Suite("Meeting apps")
struct MeetingAppsTests {
    private func process(_ bundleID: String?, input: Bool = false, output: Bool = false, pid: pid_t = 1) -> AudioProcess {
        AudioProcess(objectID: 0, pid: pid, bundleID: bundleID, isRunningOutput: output, isRunningInput: input)
    }

    @Test("an app counts when any of its helpers has the microphone open")
    func helperCounts() {
        let found = MeetingApp.recording(
            among: MeetingApp.known,
            processes: [process("com.microsoft.teams2.helper.renderer", input: true), process("com.apple.Music")],
            ownBundleID: "dev.rrios.quill"
        )
        #expect(found.map(\.id) == ["teams"])
    }

    @Test("Quill itself, idle apps and look-alike prefixes do not count")
    func nothingElseCounts() {
        let found = MeetingApp.recording(
            among: MeetingApp.known,
            processes: [
                process("dev.rrios.quill", input: true),
                process("us.zoom.xos"),
                process("com.google.Chromecast", input: true),
            ],
            ownBundleID: "dev.rrios.quill"
        )
        #expect(found.isEmpty)
    }

    @Test("a listed app is found through its helpers")
    func listedThroughHelpers() {
        let found = MeetingApp.recording(
            among: MeetingApp.known,
            processes: [process("com.hnc.Discord.helper.Renderer", input: true)],
            ownBundleID: "dev.rrios.quill"
        )
        #expect(found.map(\.id) == ["discord"])
    }

    @Test("a prefix only matches whole components")
    func wholeComponents() {
        let firefox = MeetingApp.known.first { $0.id == "firefox" }!
        #expect(firefox.matches("org.mozilla.firefox"))
        #expect(firefox.matches("org.mozilla.firefoxdeveloperedition"))
        #expect(!firefox.matches("org.mozilla.firefoxsomethingelse"))
    }

    @Test("ids are unique, and 1.1.0's are all still listed")
    func ids() {
        let ids = MeetingApp.known.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(MeetingApp.knownIn1_1_0.isSubset(of: Set(ids)))
    }

    @Test("a helper belongs to the app before .helper")
    func owningBundleID() {
        #expect(MeetingApp.owningBundleID(of: "com.example.Call.helper.Renderer") == "com.example.Call")
        #expect(MeetingApp.owningBundleID(of: "com.example.Call.Helper") == "com.example.Call")
        #expect(MeetingApp.owningBundleID(of: "com.example.Call") == "com.example.Call")
    }

    @Test("an unlisted app with the microphone open is offered, a call before a dictation app")
    func unlisted() {
        let processes = [
            process("com.example.Dictation", input: true),
            process("com.example.Call.helper", input: true),
            process("com.example.Call.helper.Renderer", output: true),
            process("com.apple.CoreSpeech", input: true),
            process("dev.rrios.ambar", input: true),
            process("dev.rrios.quill", input: true),
            process("com.microsoft.teams2", input: true),
            process(nil, input: true),
            process("com.example.Music", output: true),
        ]
        #expect(MeetingApp.unlistedRecording(processes: processes, ownBundleID: "dev.rrios.quill")
            == ["com.example.Call", "com.example.Dictation"])
    }

    @Test("an unlisted app is not one of the list and taps its helpers")
    func unlistedApp() {
        let app = MeetingApp.unlisted(bundleID: "com.example.Call", name: "Call")
        #expect(!app.isListed)
        #expect(app.matches("com.example.Call.helper"))
        #expect(MeetingApp.known.filter { !$0.isListed }.isEmpty)
    }

    @Test("Batuta is a meeting app: it holds the Mac's microphone only while a call on another computer asks for it")
    func batutaCall() {
        let batuta = MeetingApp.known.first { $0.id == "batuta" }
        #expect(batuta?.name == "Batuta")
        #expect(batuta?.isBrowser == false)
        // A call on the Linux: Batuta plays its sound in the headset and sends it the Mac's microphone.
        let call = MeetingApp.recording(
            among: MeetingApp.known,
            processes: [process("dev.rrios.batuta", input: true, output: true)],
            ownBundleID: "dev.rrios.quill")
        #expect(call.map(\.id) == ["batuta"])
        // A video on the Linux: Batuta plays, nothing asks for the microphone — no meeting.
        let video = MeetingApp.recording(
            among: MeetingApp.known,
            processes: [process("dev.rrios.batuta", output: true)],
            ownBundleID: "dev.rrios.quill")
        #expect(video.isEmpty)
        // Its MCP executable is not the app.
        #expect(batuta?.matches("dev.rrios.batutatool") == false)
    }
}
