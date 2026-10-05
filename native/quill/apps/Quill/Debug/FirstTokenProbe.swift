#if DEBUG

import Foundation
import ModelKit
import QuillSupport

/// ARCHITECTURE §11's first-token row, measured on this Mac (PLAN P5-T4): the time to
/// the first streamed token from the on-device model, cold (a fresh session, no prewarm)
/// and after `prewarm` — the gain the hot-key prewarm buys, measured separately as §11
/// asks. Writes `probe/perf.txt`. The prompt is a fixed fixture, never user text.
enum FirstTokenProbe {
    static let runs = 5

    static func run() async {
        let request = GenerationRequest(
            model: "system", instructions: "Rewrite the text with correct spelling. Return only the text.",
            input: "the meeting is moved to friday")
        var cold: [Double] = []
        var warm: [Double] = []
        for _ in 0..<runs {
            cold.append(await firstToken(AppleOnDeviceProvider(), request, prewarm: false) ?? .nan)
            warm.append(await firstToken(AppleOnDeviceProvider(), request, prewarm: true) ?? .nan)
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.filter { !$0.isNaN }.sorted()
            guard !sorted.isEmpty else { return "no token" }
            let median = sorted[sorted.count / 2]
            return String(format: "median %.0f ms, min %.0f, max %.0f (n=%d)", median, sorted.first!, sorted.last!, sorted.count)
        }
        let lines = ["cold: \(summary(cold))", "prewarmed: \(summary(warm))"]
        let url = AppPaths.current.appendingPathComponent("probe/perf.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func firstToken(_ provider: AppleOnDeviceProvider, _ request: GenerationRequest, prewarm: Bool) async -> Double? {
        if prewarm {
            await provider.prewarm(for: request)
            // The capture and the picker take this long before the request goes out.
            try? await Task.sleep(for: .milliseconds(250))
        }
        let start = ContinuousClock.now
        do {
            for try await event in provider.stream(request) {
                if case .delta(let text) = event, !text.isEmpty {
                    let elapsed = start.duration(to: .now).components
                    return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}

#endif
