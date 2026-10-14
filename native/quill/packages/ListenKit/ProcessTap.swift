import AVFAudio
import CoreAudio
import Foundation

/// Captures what a set of processes plays, before it reaches the speakers.
///
/// A Core Audio process tap (macOS 14.2+) wrapped in a private aggregate device, the
/// only way to read a tap. No virtual driver, no screen-recording permission: the system
/// asks once for "System Audio Recording", against `NSAudioCaptureUsageDescription`.
///
/// Nothing is written anywhere. Each block is handed to `onBuffer` and dropped; what a
/// meeting leaves behind is the transcript, never the audio.
public final class ProcessTap: @unchecked Sendable {
    public enum Target: Sendable {
        /// These Core Audio process objects.
        case processes([AudioObjectID])
        /// Every process with one of these bundle identifiers, including ones that start
        /// later (macOS 26): a meeting app that restarts its audio helper mid-call.
        case bundleIDs([String])
    }

    public let format: AVAudioFormat

    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?
    private let counter = DeliveryCounter()

    /// Blocks delivered so far, for the session's watchdog.
    public var deliveredBuffers: Int { counter.value }
    private let queue = DispatchQueue(label: "dev.rrios.quill.listen.tap", qos: .userInitiated)

    /// - Parameter muted: silence the tapped processes while tapping. For tests, which
    ///   play synthetic speech and should not fill the room with it; never for a meeting.
    /// - Parameter tapOnly: an aggregate with the tap and no sub-device, so the capture
    ///   does not depend on the output device. The default since 2026-10-08: with the
    ///   output device as clock, AirPods switching to their call profile — which opening
    ///   their microphone does — killed the aggregate and the meeting was never heard
    ///   (0 s captured; 46.8 s tap-only, same test).
    public init(target: Target, muted: Bool = false, tapOnly: Bool = true) throws {
        let description: CATapDescription
        switch target {
        case .processes(let ids):
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        case .bundleIDs(let ids):
            description = CATapDescription(stereoMixdownOfProcesses: [])
            description.bundleIDs = ids
            description.isProcessRestoreEnabled = true
        }
        description.uuid = UUID()
        description.name = "Quill meeting tap"
        description.isPrivate = true
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        var streamDescription: AudioStreamBasicDescription = try CoreAudioProperty.value(
            of: tap,
            selector: kAudioTapPropertyFormat
        )
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            AudioHardwareDestroyProcessTap(tap)
            throw CoreAudioError(status: -1, operation: "read tap format")
        }
        self.format = format

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Quill meeting tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if !tapOnly {
            let outputUID = try Self.defaultOutputDeviceUID()
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw CoreAudioError(status: status, operation: "create aggregate device")
        }
        self.aggregateID = aggregateID
    }

    /// Starts delivering blocks. `onBuffer` runs on a private queue with a copy it owns.
    public func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let format = self.format
        let counter = self.counter
        var procID: AudioDeviceIOProcID?
        try CoreAudioError.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                // The buffer list is only valid inside this block: copy before handing on.
                guard let view = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: input,
                    deallocator: nil
                ), view.frameLength > 0, let copy = view.copied() else { return }
                counter.increment()
                onBuffer(copy)
            },
            "create IO proc"
        )
        ioProcID = procID
        try CoreAudioError.check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
    }

    deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    static func defaultOutputDeviceUID() throws -> String {
        let device: AudioDeviceID = try CoreAudioProperty.value(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        return try CoreAudioProperty.string(of: device, selector: kAudioDevicePropertyDeviceUID)
    }
}

/// A thread-safe count.
final class DeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

extension AVAudioPCMBuffer {
    /// A deep copy that owns its memory.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
