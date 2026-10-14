#if DEBUG
import AppKit
import Foundation
import ListenKit
import SpeakerKit

/// `QUILL_LISTEN` (see `DebugHooks.listenTarget`): the meeting spike, run inside the app
/// bundle because the System Audio Recording permission belongs to an app, not to a
/// loose binary.
@MainActor
enum ListenProbe {
    static func run(target: String) async {
        let environment = ProcessInfo.processInfo.environment
        var lines: [String] = []
        func report(_ line: String) {
            print(line)
            lines.append(line)
        }
        defer {
            if let path = environment["QUILL_LISTEN_REPORT"] {
                try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }

        if target == "list" {
            do {
                for process in try AudioProcesses.all().sorted(by: { $0.pid < $1.pid }) {
                    report("LISTEN process \(process)")
                }
            } catch {
                report("LISTEN ✗ \(error)")
            }
            return
        }

        let tapTarget: ProcessTap.Target
        if target.hasPrefix("pid:"), let pid = pid_t(target.dropFirst(4)) {
            guard let object = try? AudioProcesses.objectID(forPID: pid) else {
                report("LISTEN ✗ pid \(pid) has no Core Audio process object (has it played audio?)")
                return
            }
            tapTarget = .processes([object])
        } else if target.hasPrefix("bundle:") {
            tapTarget = .bundleIDs(target.dropFirst(7).split(separator: ",").map(String.init))
        } else {
            report("LISTEN ✗ unknown target \(target)")
            return
        }

        let seconds = environment["QUILL_LISTEN_SECONDS"].flatMap(Double.init) ?? 30
        var listenConfiguration = ListenSession.Configuration(
            target: tapTarget,
            sourceName: target,
            locale: Locale(identifier: environment["QUILL_LISTEN_LOCALE"] ?? "es_ES"),
            includeMicrophone: environment["QUILL_LISTEN_MIC"] != nil,
            muteTarget: environment["QUILL_LISTEN_MUTE"] != nil,
            keepsOthersAudio: environment["QUILL_LISTEN_SPEAKERS"] != nil
        )
        // Device-change experiments (MEETINGS.md, Bluetooth finding).
        // The aggregate with the output device as clock is kept only to reproduce the failure.
        listenConfiguration.tapOnly = environment["QUILL_LISTEN_OUTPUTCLOCK"] == nil
        listenConfiguration.echoCancellation = environment["QUILL_LISTEN_NOVP"] == nil
        listenConfiguration.microphoneFirst = environment["QUILL_LISTEN_MICFIRST"] != nil
        report("LISTEN config tapOnly=\(listenConfiguration.tapOnly) vp=\(listenConfiguration.echoCancellation) micFirst=\(listenConfiguration.microphoneFirst)")
        let session = ListenSession(configuration: listenConfiguration)
        let started = ContinuousClock.now
        do {
            try await session.start { segment in
                print("LISTEN segment \(segment.channel.rawValue) \(String(format: "%.1f", segment.start))-\(String(format: "%.1f", segment.end)) \(segment.text)")
            }
        } catch {
            report("LISTEN ✗ start: \(error)")
            return
        }
        report("LISTEN started in \(started.duration(to: .now))")
        // `QUILL_LISTEN_BREAK_AT=<s>`: lose the others' capture mid-meeting, as a device
        // change does, to test the watchdog's recovery.
        if let breakAt = environment["QUILL_LISTEN_BREAK_AT"].flatMap(Double.init), breakAt < seconds {
            try? await Task.sleep(for: .seconds(breakAt))
            session.simulateCaptureLoss()
            report("LISTEN capture broken at \(breakAt) s")
            try? await Task.sleep(for: .seconds(seconds - breakAt))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        let captured = session.secondsCaptured
        for line in session.diagnostics { report("LISTEN diag \(line)") }
        let stopping = ContinuousClock.now
        var transcript = await session.stop()
        report("LISTEN stopped; last segments took \(stopping.duration(to: .now))")
        // Before diarization, while the words still carry their times (scored by the bench).
        if let path = environment["QUILL_LISTEN_REPORT"], let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: URL(fileURLWithPath: path + ".raw.json"))
        }
        if let speakers = environment["QUILL_LISTEN_SPEAKERS"] {
            let samples = session.takeOthersAudio()
            let directory = URL(fileURLWithPath: environment["QUILL_DATA_DIR"] ?? NSTemporaryDirectory())
                .appending(path: "models")
            let separator = SpeakerSeparator(modelsDirectory: directory, expectedSpeakers: Int(speakers))
            do {
                let loading = ContinuousClock.now
                try await separator.prepare()
                report("SPEAKERS models ready in \(loading.duration(to: .now))")
                let separating = ContinuousClock.now
                // As the product does (MeetingsCoordinator.finish).
                let turns = SpeakerTurn.absorbingMinorVoices(try await separator.turns(for: samples))
                if let path = environment["QUILL_LISTEN_REPORT"] {
                    let rows = turns.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end] as [String: Any] }
                    if let data = try? JSONSerialization.data(withJSONObject: rows) {
                        try? data.write(to: URL(fileURLWithPath: path + ".turns.json"))
                    }
                }
                report("SPEAKERS \(String(format: "%.1f", Double(samples.count) / AudioAccumulator.sampleRate)) s separated in \(separating.duration(to: .now))")
                for turn in turns {
                    report("SPEAKERS turn \(turn.speaker) \(String(format: "%.2f", turn.start))-\(String(format: "%.2f", turn.end))")
                }
                transcript = transcript.assigningSpeakers(turns)
            } catch {
                report("SPEAKERS ✗ \(error)")
            }
        }
        for (channel, value) in captured.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            report("LISTEN captured \(channel.rawValue)=\(String(format: "%.1f", value)) s")
        }
        report("LISTEN segments=\(transcript.segments.count)")
        report("LISTEN --- transcript ---")
        report(transcript.rendered())
        if let path = environment["QUILL_LISTEN_REPORT"],
           let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: URL(fileURLWithPath: path + ".json"))
        }
    }
}
#endif
