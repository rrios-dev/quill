import Foundation

/// Waits by polling, never by sleeping a fixed time (ARCHITECTURE §3.2): a fixed delay
/// works on the machine of whoever wrote it and fails on the user's.
public enum Polling {
    /// The interval every SelectionKit wait polls at.
    public static let interval: Duration = .milliseconds(4)

    /// Polls `condition` until it holds or `timeout` passes. Returns whether it held.
    ///
    /// Behind any `Clock`, so tests drive it with a manual clock instead of real time.
    public static func wait<C: Clock>(
        timeout: Duration,
        clock: C,
        until condition: () async -> Bool
    ) async -> Bool where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if await condition() { return true }
            if clock.now >= deadline { return false }
            do {
                try await clock.sleep(for: interval)
            } catch {
                return false
            }
        }
    }
}
