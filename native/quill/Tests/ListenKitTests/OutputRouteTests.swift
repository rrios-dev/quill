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
}
