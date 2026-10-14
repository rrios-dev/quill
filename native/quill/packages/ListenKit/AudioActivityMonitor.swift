import CoreAudio
import Foundation

/// Calls back when any process starts or stops using the microphone.
///
/// Event-driven, never polled: it listens to Core Audio's process list and to each
/// process's "is running input" flag, so a meeting is noticed the moment its app opens
/// the microphone and the monitor costs nothing while nothing changes.
public final class AudioActivityMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.rrios.quill.listen.activity")
    private let onChange: @Sendable ([AudioProcess]) -> Void
    private var listened: Set<AudioObjectID> = []
    private var listBlock: AudioObjectPropertyListenerBlock?
    private var inputBlock: AudioObjectPropertyListenerBlock?
    private var running = false

    /// - Parameter onChange: called on the main queue with every process now using the
    ///   microphone, after each change and once at start.
    public init(onChange: @escaping @Sendable ([AudioProcess]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let list: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            let input: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
            listBlock = list
            inputBlock = input
            var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, list)
            refresh()
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            if let listBlock {
                var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listBlock)
            }
            if let inputBlock {
                for object in listened {
                    var address = CoreAudioProperty.address(kAudioProcessPropertyIsRunningInput)
                    AudioObjectRemovePropertyListenerBlock(object, &address, queue, inputBlock)
                }
            }
            listened = []
        }
    }

    deinit { stop() }

    /// On the private queue: follow new processes, forget gone ones, then report.
    private func refresh() {
        guard running, let inputBlock else { return }
        let current = Set((try? CoreAudioProperty.array(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        ) as [AudioObjectID]) ?? [])
        for object in current.subtracting(listened) {
            var address = CoreAudioProperty.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectAddPropertyListenerBlock(object, &address, queue, inputBlock)
        }
        listened = current
        report()
    }

    private func report() {
        let recording = ((try? AudioProcesses.all()) ?? []).filter(\.isRunningInput)
        let onChange = self.onChange
        DispatchQueue.main.async { onChange(recording) }
    }
}
