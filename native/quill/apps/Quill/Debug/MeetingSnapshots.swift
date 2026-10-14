#if DEBUG
import AppKit
import Foundation
import ListenKit
import MeetingKit
import SynthesisKit

/// `QUILL_SNAPSHOT_MEETINGS` (see `DebugHooks.snapshotsMeetings`): every meetings
/// surface with real data, for review screenshots.
@MainActor
enum MeetingSnapshots {
    static func run(meetings: MeetingsCoordinator, transcriptPath: String,
                    openSettings: @escaping () -> Void, settingsWindow: @escaping () -> NSWindow?) async {
        func settle() async { try? await Task.sleep(for: .milliseconds(1_200)) }
        func snap(_ surface: String, _ window: NSWindow?) async {
            guard let window else {
                print("SNAP-MISSING \(surface)")
                return
            }
            print("SNAP \(surface) \(window.windowNumber)")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(2))
        }
        guard let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            print("SNAP-ERROR no transcript at \(transcriptPath)")
            NSApp.terminate(nil)
            return
        }
        let record = seed(text: text, store: meetings.store)
        let teams = MeetingApp.known[0]
        meetings.debugStopMonitor()
        // The monitor's first report was queued at launch: let it land before the offer,
        // or it closes the offer at once (Teams is not in a call).
        await settle()

        meetings.offer(teams)
        await settle()
        await snap("offer", meetings.debugOfferWindow)
        meetings.debugReset()

        meetings.debugShowLive(app: teams, segments: Array(record.transcript.ordered.prefix(6)).map {
            var segment = $0
            segment.speaker = nil
            return segment
        })
        await settle()
        await snap("live", meetings.debugLiveWindow)
        // During the meeting: voices told apart and partly named, an English meeting
        // translated, then folded into the orb.
        meetings.debugLiveVoices(names: ["speaker-1": "Lucía", "speaker-2": "Andrés"],
                                 roles: ["speaker-1": "tech-lead"])
        meetings.debugTranslate(["Okay, let's start with the migration.", "It takes three and a half hours.",
                                 "We can't stop billing that long.", "What about logical replication?",
                                 "Fifteen to twenty minutes of downtime.", "That's a week more of work."])
        await settle()
        await snap("live-voices", meetings.debugLiveWindow)
        meetings.debugCollapseLive()
        await settle()
        await snap("live-orb", meetings.debugLiveWindow)
        meetings.debugReset()

        meetings.openMeeting(record.id, step: .people)
        if let window = meetings.debugMeetingWindow(record.id), let screen = window.screen ?? NSScreen.main {
            // As tall as the screen allows: the review is of the analysis, not its first fold.
            window.setFrame(NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY,
                                   width: min(1280, screen.visibleFrame.width), height: screen.visibleFrame.height), display: true)
        }
        await settle()
        await snap("meeting", meetings.debugMeetingWindow(record.id))
        if let model = meetings.debugMeetingModel(record.id) {
            model.choose(focus: "analysis")
            await settle()
            await snap("meeting-analysis", meetings.debugMeetingWindow(record.id))
            model.choose(focus: "brief")
            model.toggleSelection(record.labels.dropFirst().first ?? "me")
            await settle()
            await snap("meeting-filter", meetings.debugMeetingWindow(record.id))
            model.toggleSelection(record.labels.dropFirst().first ?? "me")
            model.choose(focus: "work")
            // Every layout (MeetingLayout): the owner's portrait screen whole and halved
            // by a tiler, a narrow tall tile, a small window.
            for (name, size) in [("portrait", NSSize(width: 1080, height: 2300)), ("tile", NSSize(width: 1080, height: 1180)),
                                 ("narrow", NSSize(width: 520, height: 1100)), ("small", NSSize(width: 640, height: 520)),
                                 ("narrow-tall", NSSize(width: 480, height: 2300))] {
                if let window = meetings.debugMeetingWindow(record.id), let screen = window.screen ?? NSScreen.main {
                    let height = min(size.height, screen.visibleFrame.height)
                    window.setFrame(NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.maxY - height,
                                           width: size.width, height: height), display: true)
                }
                await settle()
                await snap("meeting-\(name)", meetings.debugMeetingWindow(record.id))
            }
        }
        meetings.debugMeetingWindow(record.id)?.close()

        meetings.openHistory()
        await settle()
        await snap("history", meetings.history?.shownWindow)
        meetings.history?.shownWindow?.close()

        openSettings()
        await settle()
        await settle()
        await snap("settings", settingsWindow())
        settingsWindow()?.close()

        meetings.openFocusEditor()
        await settle()
        await snap("focus", meetings.debugFocusEditorWindow)
        NSApp.terminate(nil)
    }

    /// A meeting from `[hh:mm:ss] Name: text` lines: "Yo" is the microphone, everyone
    /// else becomes a diarized speaker, with names and roles as if the user had set them.
    static func seed(text: String, store: MeetingStore) -> MeetingRecord {
        var segments: [TranscriptSegment] = []
        var labels: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"), let colon = line[close...].firstIndex(of: ":")
            else { continue }
            let clock = line[line.index(after: line.startIndex)..<close].split(separator: ":").compactMap { Double($0) }
            let start = clock.count == 3 ? clock[0] * 3600 + clock[1] * 60 + clock[2] : 0
            let name = line[line.index(close, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces)
            let said = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "Yo" {
                segments.append(TranscriptSegment(channel: .me, start: start, end: start + 5, text: said))
            } else {
                let label = labels[name] ?? "speaker-\(labels.count + 1)"
                labels[name] = label
                segments.append(TranscriptSegment(channel: .others, start: start, end: start + 5, text: said, speaker: label))
            }
        }
        let roleOf = ["Lucía": "tech-lead", "Andrés": "tech-lead", "Marta": "support", "Diego": "engineer"]
        var names = ["me": "Roberto"]
        var people: [String: UUID] = [:]
        if let me = try? store.remember(name: "Roberto", roleID: "product-owner") { people["me"] = me.id }
        for (name, label) in labels where name != "Diego" {
            names[label] = name
            if let person = try? store.remember(name: name, roleID: roleOf[name]) { people[label] = person.id }
        }
        var record = MeetingRecord(
            title: "Reunión semanal de producto", sourceApp: "Microsoft Teams",
            startedAt: Date().addingTimeInterval(-3_600), duration: 1_920,
            transcript: Transcript(startedAt: Date(), locale: "es_ES", source: "teams", segments: segments, names: names),
            people: people
        )
        // Ready-made syntheses per focus, so the review shows each kind of result.
        for (variable, focus) in [("QUILL_SNAPSHOT_SYNTHESIS", SynthesisFocus.work),
                                  ("QUILL_SNAPSHOT_ANALYSIS", SynthesisFocus.analysis)] {
            guard let path = DebugHooks.value(variable),
                  let synthesis = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let participants = focus.weighting.participants(store.people(in: record))
            record.syntheses.append(SynthesisRecord(focusID: focus.id, focusName: focus.name,
                                                    model: "openrouter:anthropic/claude-sonnet-5.5",
                                                    text: synthesis, participants: participants))
        }
        try? store.save(record)
        return record
    }
}
#endif
