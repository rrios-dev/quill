import Foundation
import Testing
@testable import ListenKit

struct MicrophoneGateTests {
    @Test(arguments: [
        ("Silenciar (⌘+Mayús+M)", MuteLabel.State.live),
        ("Reactivar audio (⌘+Mayús+M)", .muted),
        ("Mute (⌘+Shift+M)", .live),
        ("Unmute (⌘+Shift+M)", .muted),
        ("Mute audio", .live),
        ("Unmute audio", .muted),
        ("Desactivar micrófono (⌘ + d)", .live),
        ("Activar micrófono (⌘ + d)", .muted),
        ("Turn off microphone", .live),
        ("Turn on microphone", .muted),
        ("Silenciar audio", .live),
        ("Dejar de silenciar", .muted),
    ])
    func readsTheMicrophoneFromTheControlLabel(label: String, expected: MuteLabel.State) {
        #expect(MuteLabel.state(of: label) == expected)
    }

    @Test(arguments: ["Silenciar a todos", "Mute all", "Silenciar notificaciones", "Cámara", "Turn off camera", "Compartir"])
    func otherControlsAreNotTheMicrophone(label: String) {
        #expect(MuteLabel.state(of: label) == nil)
    }

    @Test func anySourceMutesAndTheUserSwitchWins() {
        let gate = MicrophoneGate()
        #expect(!gate.isMuted)
        gate.setAppHoldsMicrophone(true)
        gate.setAppControlMuted(nil)
        #expect(!gate.isMuted)
        gate.setAppControlMuted(true)
        #expect(gate.mutedReason == .mutedInApp)
        gate.setAppControlMuted(false)
        gate.setAppHoldsMicrophone(false)
        #expect(gate.mutedReason == .appReleasedMicrophone)
        gate.setUserMuted(true)
        #expect(gate.mutedReason == .mutedInQuill)
    }

    @Test func tellsOnlyWhenTheDecisionChanges() {
        let gate = MicrophoneGate()
        let seen = Seen()
        gate.observe { seen.add($0) }
        gate.setAppHoldsMicrophone(true)
        gate.setAppControlMuted(true)
        gate.setAppControlMuted(true)
        gate.setAppControlMuted(false)
        #expect(seen.values == [.mutedInApp, nil])
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [MicrophoneGate.Reason?] = []
    func add(_ value: MicrophoneGate.Reason?) { lock.withLock { all.append(value) } }
    var values: [MicrophoneGate.Reason?] { lock.withLock { all } }
}
