#if DEBUG

import Foundation
import ModelKit
import QuillSupport

/// Debug → Live provider test (ARCHITECTURE §3.6, PROVIDERS §8 item 4).
///
/// Runs a burst of on-device generations from inside the app — an `LSUIElement` agent
/// that never activates, which the framework may treat as a background process and
/// throttle — through the same streaming path the picker uses, and records how many
/// were rate-limited, how many needed the provider's one retry, and how long each took.
struct LiveProviderTest: Sendable {
    struct Row: Codable, Sendable {
        var kind = "liveProvider"
        var date: Date
        var tag: String?
        var calls: Int
        var succeeded: Int
        var retried: Int
        /// Calls that failed even after the retry, by error code.
        var failures: [String: Int]
        /// The 1-based index of the first call that needed a retry or failed.
        var firstThrottledCall: Int?
        var latenciesMilliseconds: [Double]
        var availability: String
    }

    static let burst = 30

    func run(tag: String?) async -> Row {
        let retries = Counter()
        let provider = AppleOnDeviceProvider(onRetry: { retries.increment() })
        var row = Row(date: Date(), tag: tag, calls: Self.burst, succeeded: 0, retried: 0, failures: [:],
                      latenciesMilliseconds: [], availability: "\(await provider.availability())")
        let request = GenerationRequest(
            model: AppleOnDeviceProvider.modelID,
            instructions: "Fix the spelling of the user's text. Return only the corrected text.",
            input: "teh meeting is tomorow at 5, see u there",
            options: GenerationOptions(temperature: 0, timeout: .seconds(30)))
        let clock = ContinuousClock()
        for index in 1...Self.burst {
            let before = retries.value
            let start = clock.now
            var failure: String?
            do {
                for try await _ in provider.stream(request) {}
            } catch let error as ProviderError {
                failure = "\(error.code)"
            } catch {
                failure = "\(error)"
            }
            row.latenciesMilliseconds.append(ProbeRunner.milliseconds(clock.now - start))
            let retried = retries.value > before
            if let failure {
                row.failures[failure, default: 0] += 1
            } else {
                row.succeeded += 1
            }
            if (retried || failure != nil), row.firstThrottledCall == nil { row.firstThrottledCall = index }
        }
        row.retried = retries.value
        QuillLog(category: "live-provider").info(
            "burst: \(row.succeeded)/\(row.calls) ok, \(row.retried) retried, failures \(row.failures)")
        return row
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}

#endif
