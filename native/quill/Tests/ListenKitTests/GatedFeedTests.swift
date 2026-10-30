import AVFAudio
import Foundation
import Testing
@testable import ListenKit

struct GatedFeedTests {
    static func block(_ value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = value }
        return buffer
    }

    /// Blocks of 0.1 s, each tagged by its value; returns what was fed, 0 for silence.
    static func run(muteAt: Int?, unmuteAt: Int? = nil, blocks: Int = 20) -> [Float] {
        let gate = MicrophoneGate()
        let fed = Fed()
        let feed = GatedFeed(gate: gate, delay: 0.3) { buffer, _ in fed.add(buffer.floatChannelData![0][0]) }
        for index in 0..<blocks {
            if index == muteAt { gate.setAppControlMuted(true) }
            if index == unmuteAt { gate.setAppControlMuted(false) }
            feed.push(block(Float(index + 1)), start: Double(index) * 0.1)
        }
        feed.flush()
        return fed.values
    }

    @Test func feedsEverythingWhileOpenAndKeepsTheTimeline() {
        let fed = Self.run(muteAt: nil)
        #expect(fed == (1...20).map(Float.init))
    }

    @Test func aMuteNoticedLateStillSilencesWhatWasWaiting() {
        // Muted from block 10 on: blocks 8 and 9 were still waiting, so they go too.
        let fed = Self.run(muteAt: 10)
        #expect(fed.count == 20)
        #expect(fed.prefix(7) == ArraySlice((1...7).map(Float.init)))
        #expect(fed.dropFirst(7).allSatisfy { $0 == 0 })
    }

    @Test func speechAfterUnmutingIsFedAgain() {
        let fed = Self.run(muteAt: 5, unmuteAt: 12)
        #expect(fed.count == 20)
        #expect(fed.suffix(8) == ArraySlice((13...20).map(Float.init)))
    }

    @Test func withoutAGateNothingWaits() {
        let fed = Fed()
        let feed = GatedFeed(gate: nil, delay: 0.6) { buffer, _ in fed.add(buffer.floatChannelData![0][0]) }
        feed.push(Self.block(1), start: 0)
        #expect(fed.values == [1])
    }
}

final class Fed: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Float] = []
    func add(_ value: Float) { lock.withLock { all.append(value) } }
    var values: [Float] { lock.withLock { all } }
}
