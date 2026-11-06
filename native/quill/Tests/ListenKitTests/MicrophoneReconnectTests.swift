import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import ListenKit

/// A microphone that disappears mid-meeting and comes back: the capture must deliver from
/// it again. Reported 2026-11-06: a headset dropped during a call, was reconnected, and
/// "me" never came back.
///
/// The headset is played by a private aggregate device wrapping the default input:
/// destroying it is the device going away, creating it again is the device coming back
/// (with a new id, as a reconnected Bluetooth headset gets). Opt-in (`QUILL_LIVE_MIC=1`):
/// it needs a real input device and microphone access.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QUILL_LIVE_MIC"] != nil), .serialized)
struct MicrophoneReconnectTests {
    /// With and without echo cancellation: on speakers it is on, and it changes the graph.
    @Test(arguments: [false, true])
    func deliversAgainAfterTheDeviceComesBack(echoCancellation: Bool) async throws {
        let wrapped = try #require(Self.defaultInputUID())
        var device = try Self.createAggregate(wrapping: wrapped)
        let capture = MicrophoneCapture(echoCancellation: echoCancellation)
        capture.use(device: device)
        try capture.start { _ in }
        defer { capture.stop() }

        try await Self.waitForBuffers(capture, beyond: 0)

        // The headset drops; the meeting app falls back to the default microphone.
        Self.destroyAggregate(device)
        try await Task.sleep(for: .seconds(1))
        capture.use(device: nil)
        try await Self.waitForBuffers(capture, beyond: capture.deliveredBuffers)

        // It comes back with a new id, and the meeting app switches to it.
        device = try Self.createAggregate(wrapping: wrapped)
        defer { Self.destroyAggregate(device) }
        capture.use(device: device)
        try await Self.waitForBuffers(capture, beyond: capture.deliveredBuffers)
        // Settled: no restart loop once it delivers.
        let restarts = Self.restarts(capture)
        try await Task.sleep(for: .seconds(3))
        #expect(Self.restarts(capture) == restarts, "\(capture.diagnostics)")
    }

    @Test func deliversAgainWhenTheSameDeviceIsRestartedAfterVanishing() async throws {
        let wrapped = try #require(Self.defaultInputUID())
        var device = try Self.createAggregate(wrapping: wrapped)
        let capture = MicrophoneCapture(echoCancellation: false)
        capture.use(device: device)
        try capture.start { _ in }
        defer { capture.stop() }
        try await Self.waitForBuffers(capture, beyond: 0)

        // Gone with nobody switching: only the session's watchdog restarts it.
        Self.destroyAggregate(device)
        try await Task.sleep(for: .seconds(1))
        device = try Self.createAggregate(wrapping: wrapped)
        defer { Self.destroyAggregate(device) }
        capture.use(device: device)
        capture.restart()
        try await Self.waitForBuffers(capture, beyond: capture.deliveredBuffers)
    }

    // MARK: Helpers

    static func restarts(_ capture: MicrophoneCapture) -> Int {
        capture.diagnostics.split(separator: " ").first { $0.hasPrefix("restarts=") }
            .flatMap { Int($0.dropFirst("restarts=".count)) } ?? -1
    }

    /// Waits up to eight seconds for more than `count` blocks.
    static func waitForBuffers(_ capture: MicrophoneCapture, beyond count: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if capture.deliveredBuffers > count + 2 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("no blocks beyond \(count): \(capture.diagnostics)", sourceLocation: sourceLocation)
    }

    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    static func createAggregate(wrapping uid: String) throws -> AudioDeviceID {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "dev.rrios.quill.test.reconnect.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Quill reconnect test",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceMainSubDeviceKey: uid,
        ]
        var device = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr else { throw CocoaError(.featureUnsupported) }
        return device
    }

    static func destroyAggregate(_ device: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(device)
    }
}
