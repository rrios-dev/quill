import Foundation

/// The seam providers that drive a local command-line tool depend on, as
/// `HTTPTransport` is for remote ones. Production uses `FoundationProcessRunner`;
/// tests inject a scripted runner, so no test ever launches a real tool.
public protocol ProcessRunner: Sendable {
    /// Launches `invocation` and yields its standard output line by line.
    ///
    /// The stream finishes when the process exits with status 0, and throws
    /// `ProcessFailure` for any other status, after every line it printed. When the
    /// consumer stops listening the process is terminated.
    func lines(_ invocation: ProcessInvocation) -> AsyncThrowingStream<String, any Error>
}

/// Everything needed to launch a tool once.
public struct ProcessInvocation: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    /// The whole environment of the child; nothing is inherited implicitly.
    public var environment: [String: String]
    public var workingDirectory: URL
    /// Written to standard input, which is then closed.
    public var standardInput: Data

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
                standardInput: Data) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
    }
}

/// A process that could not be launched, or exited with a non-zero status.
public struct ProcessFailure: Error, Sendable, Hashable {
    /// `nil` when the process never started.
    public var status: Int32?
    /// The end of what it wrote to standard error, for diagnostics.
    public var standardError: String

    public init(status: Int32?, standardError: String) {
        self.status = status
        self.standardError = standardError
    }
}

public struct FoundationProcessRunner: ProcessRunner {
    /// How much of standard error a failure keeps.
    static let standardErrorLimit = 4_096

    public init() {}

    public func lines(_ invocation: ProcessInvocation) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.environment = invocation.environment
            process.currentDirectoryURL = invocation.workingDirectory
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            // Standard error is drained as it arrives, or a chatty tool could fill the
            // pipe and block before it exits.
            let errorTail = ErrorTail(limit: Self.standardErrorLimit)
            errors.fileHandleForReading.readabilityHandler = { handle in errorTail.append(handle.availableData) }
            let exited = AsyncStream<Int32> { exit in
                process.terminationHandler = { exit.yield($0.terminationStatus); exit.finish() }
            }

            let task = Task {
                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: ProcessFailure(status: nil, standardError: String(describing: error)))
                    return
                }
                let stdin = input.fileHandleForWriting
                try? stdin.write(contentsOf: invocation.standardInput)
                try? stdin.close()
                do {
                    // Terminating the process closes the pipe, which ends this loop too.
                    for try await line in output.fileHandleForReading.bytes.lines { continuation.yield(line) }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                var status: Int32 = 0
                for await code in exited { status = code }
                errors.fileHandleForReading.readabilityHandler = nil
                if status == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProcessFailure(status: status, standardError: errorTail.text))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// The last `limit` bytes of a stream, as text.
private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data = data.suffix(limit) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
