import CoreAudio
import Foundation

/// Where the user hears the meeting: in their ears, or out loud in the room.
///
/// It decides whether the microphone needs echo cancellation. Voice processing is what
/// keeps the others' voices out of "me" when they come out of speakers — and it is also
/// what turned the meeting down: Apple's voice-processing unit ducks every other app's
/// audio while it runs, Teams included. Reported by the owner on 2026-10-08 with AirPods:
/// the call dropped to a whisper as soon as Quill started listening and came back when
/// it stopped. With headphones the microphone cannot hear the meeting, so there is no
/// echo to cancel and nothing to duck.
public enum OutputRoute: Equatable, Sendable {
    /// Headphones of any kind: the microphone does not hear the meeting.
    case headphones
    /// Speakers, a display, AirPlay: the meeting reaches the microphone through the room.
    case speakers

    /// The route of the default output device now. Unknown counts as `speakers`: an echo in
    /// the transcript is worse than the ducking it costs.
    public static func current() -> OutputRoute {
        guard let device: AudioDeviceID = try? CoreAudioProperty.value(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ), let transport: UInt32 = try? CoreAudioProperty.value(
            of: device, selector: kAudioDevicePropertyTransportType
        ) else { return .speakers }
        return route(transport: transport, dataSource: dataSource(of: device))
    }

    /// The decision, apart from the hardware so it can be tested.
    static func route(transport: UInt32, dataSource: UInt32?) -> OutputRoute {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in output is one device; the jack shows as its data source.
            return dataSource == headphonesDataSource ? .headphones : .speakers
        default:
            return .speakers
        }
    }

    /// 'hdpn', the built-in output's headphone jack.
    static let headphonesDataSource: UInt32 = 0x6864_706E

    private static func dataSource(of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
