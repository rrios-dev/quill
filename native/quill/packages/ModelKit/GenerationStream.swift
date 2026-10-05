import Foundation

/// Shared plumbing for `ModelProvider.stream`, so every provider gets the same
/// cancellation, timeout and error-normalisation behaviour instead of
/// reimplementing it slightly differently.
enum GenerationStream {
    /// Runs `body` as a stream that:
    /// - stops the work when the consumer stops listening (task cancellation);
    /// - fails with `.timeout` once `timeout` elapses;
    /// - only ever throws `ProviderError`.
    static func make(
        provider: ProviderID,
        timeout: Duration,
        body: @escaping @Sendable (AsyncThrowingStream<GenerationEvent, any Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<GenerationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await body(continuation) }
                        group.addTask {
                            try await Task.sleep(for: timeout)
                            throw ProviderError(.timeout, "No result after \(timeout).", provider: provider)
                        }
                        // Whichever finishes first decides; the other is cancelled.
                        try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch {
                    // A cancelled consumer surfaces as `.cancelled`, whatever the
                    // underlying layer threw while being torn down.
                    let normalized = Task.isCancelled
                        ? ProviderError(.cancelled, "Cancelled.", provider: provider)
                        : ProviderError.normalize(error, provider: provider)
                    continuation.finish(throwing: normalized)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ContinuousClock.Instant {
    var elapsed: Duration { ContinuousClock.now - self }
}
