import CoreAudio
import Foundation

/// A process that Core Audio knows about: something that has opened an audio device.
///
/// Meeting apps rarely play audio from their main process. Teams renders it from a
/// WebView helper and Meet from a browser helper, so the process to tap is found by
/// listing what Core Audio sees and matching bundle identifiers, not by asking
/// `NSWorkspace` for the app the user clicked on.
public struct AudioProcess: Sendable, Hashable, CustomStringConvertible {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// The process is playing audio right now.
    public let isRunningOutput: Bool
    /// The process is recording audio right now (a meeting app with the microphone open).
    public let isRunningInput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isRunningOutput: Bool, isRunningInput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }

    public var description: String {
        let flags = (isRunningOutput ? "out" : "-") + "/" + (isRunningInput ? "in" : "-")
        return "\(pid) \(bundleID ?? "?") [\(flags)]"
    }
}

public enum AudioProcesses {
    /// Every process Core Audio currently tracks.
    public static func all() throws -> [AudioProcess] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
        return ids.compactMap { id in
            guard let pid: pid_t = try? CoreAudioProperty.value(of: id, selector: kAudioProcessPropertyPID)
            else { return nil }
            let bundleID = try? CoreAudioProperty.string(of: id, selector: kAudioProcessPropertyBundleID)
            let output: UInt32 = (try? CoreAudioProperty.value(of: id, selector: kAudioProcessPropertyIsRunningOutput)) ?? 0
            let input: UInt32 = (try? CoreAudioProperty.value(of: id, selector: kAudioProcessPropertyIsRunningInput)) ?? 0
            return AudioProcess(
                objectID: id,
                pid: pid,
                bundleID: bundleID?.isEmpty == true ? nil : bundleID,
                isRunningOutput: output != 0,
                isRunningInput: input != 0
            )
        }
    }

    /// The Core Audio object for a process id, if the process has touched audio.
    public static func objectID(forPID pid: pid_t) throws -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )
        try CoreAudioError.check(status, "translate pid \(pid)")
        return object == kAudioObjectUnknown ? nil : object
    }

    /// Processes whose bundle identifier starts with any of `prefixes`: an app and its
    /// helpers (`com.microsoft.teams2`, `com.microsoft.teams2.helper…`).
    public static func matching(bundlePrefixes prefixes: [String]) throws -> [AudioProcess] {
        try all().filter { process in
            guard let bundleID = process.bundleID else { return false }
            return prefixes.contains { bundleID.hasPrefix($0) }
        }
    }
}

/// Typed reads of Core Audio properties.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func value<T>(of object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        try CoreAudioError.check(status, "read property \(selector)")
        return pointer.pointee
    }

    static func array<T>(of object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        try CoreAudioError.check(
            AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
            "size of property \(selector)"
        )
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        try CoreAudioError.check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer),
            "read property \(selector)"
        )
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    static func string(of object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try CoreAudioError.check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
            "read string property \(selector)"
        )
        return value?.takeRetainedValue() as String? ?? ""
    }
}

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String { "\(operation) failed (OSStatus \(status))" }

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
    }
}
