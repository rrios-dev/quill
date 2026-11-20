import CoreAudio
import Testing

@testable import ListenKit

/// Whether the microphone needs echo cancellation, and so whether the meeting gets ducked.
@Suite("Output route")
struct OutputRouteTests {
    @Test("Bluetooth headphones are private: no echo to cancel, nothing ducked")
    func bluetoothIsHeadphones() {
        #expect(OutputRoute.route(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil) == .headphones)
        #expect(OutputRoute.route(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil) == .headphones)
    }

    @Test("the built-in output is headphones only when the jack is in use")
    func builtInDependsOnTheJack() {
        let builtIn = kAudioDeviceTransportTypeBuiltIn
        #expect(OutputRoute.route(transport: builtIn, dataSource: OutputRoute.headphonesDataSource) == .headphones)
        #expect(OutputRoute.route(transport: builtIn, dataSource: 0x6973_706B) == .speakers) // 'ispk'
        #expect(OutputRoute.route(transport: builtIn, dataSource: nil) == .speakers)
    }

    @Test("anything else is the room: an echo in the transcript is worse than ducking")
    func unknownIsSpeakers() {
        #expect(OutputRoute.route(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil) == .speakers)
        #expect(OutputRoute.route(transport: kAudioDeviceTransportTypeAirPlay, dataSource: nil) == .speakers)
    }

    /// 2026-11-17: `current()` read the default output as an inferred `AudioDeviceID?`,
    /// the read failed on every Mac, and every device counted as speakers — voice
    /// processing ducked the owner's call on Bluetooth headphones. Reading the real
    /// device must work and agree with the decision taken from its transport.
    @Test("the live route is read from the real default output, not assumed")
    func liveRouteReadsTheDevice() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let device = try CoreAudioProperty.value(
            AudioDeviceID.self, of: system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard device != kAudioObjectUnknown else { return } // a runner without audio
        let transport = try CoreAudioProperty.value(
            UInt32.self, of: device, selector: kAudioDevicePropertyTransportType)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            #expect(OutputRoute.current() == .headphones)
        }
        if transport == kAudioDeviceTransportTypeHDMI {
            #expect(OutputRoute.current() == .speakers)
        }
    }
}
