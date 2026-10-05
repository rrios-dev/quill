import CoreGraphics
import Foundation
import ModelKit
import RewriteKit
import SelectionKit

@testable import Quill

/// A provider whose answers the test scripts, and which records what reached it.
final class FakeProvider: ModelProvider, @unchecked Sendable {
    let descriptor: ProviderDescriptor
    private let lock = NSLock()
    private var _availability: ProviderAvailability = .available
    private var _reply = "The meeting has moved to Friday."
    private var _finish: FinishReason = .stop
    private var _error: ProviderError?
    private var _hold = false
    private var _streamInputs: [String] = []
    private var _streamInstructions: [String] = []
    private var _prewarms = 0
    private var _models: Result<[ModelDescriptor], ProviderError> = .success([])
    private var _modelFetches = 0
    private var release: CheckedContinuation<Void, Never>?

    init(id: ProviderID, name: String, onDevice: Bool, context: Int?) {
        let execution: ProviderTraits.Execution = onDevice ? .onDevice : .remote(recipients: [.named(name), .routedInferenceProvider])
        descriptor = ProviderDescriptor(
            id: id, displayName: name,
            traits: ProviderTraits(execution: execution, cost: onDevice ? .free : .payPerUse,
                                   credential: onDevice ? .none : .apiKey, maxContextTokens: context))
    }

    var availabilityValue: ProviderAvailability {
        get { lock.withLock { _availability } }
        set { lock.withLock { _availability = newValue } }
    }
    var reply: String {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }
    var finish: FinishReason {
        get { lock.withLock { _finish } }
        set { lock.withLock { _finish = newValue } }
    }
    var error: ProviderError? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    /// Streams one delta and then waits until `releaseHold()` or cancellation.
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    /// The inputs (the user message) of every request that reached the provider.
    var streamInputs: [String] { lock.withLock { _streamInputs } }
    var streamInstructions: [String] { lock.withLock { _streamInstructions } }
    var prewarms: Int { lock.withLock { _prewarms } }

    func releaseHold() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            _hold = false
            defer { release = nil }
            return release
        }
        continuation?.resume()
    }

    func availability() async -> ProviderAvailability { availabilityValue }
    /// What `models()` answers, and how often it was asked.
    var modelsResult: Result<[ModelDescriptor], ProviderError> {
        get { lock.withLock { _models } }
        set { lock.withLock { _models = newValue } }
    }
    var modelFetches: Int { lock.withLock { _modelFetches } }

    func models() async throws -> [ModelDescriptor] {
        let result = lock.withLock { () -> Result<[ModelDescriptor], ProviderError> in
            _modelFetches += 1
            return _models
        }
        return try result.get()
    }
    func prewarm(for request: GenerationRequest) async { lock.withLock { _prewarms += 1 } }

    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        lock.withLock {
            _streamInputs.append(request.input)
            _streamInstructions.append(request.instructions)
        }
        let (reply, finish, error, hold) = lock.withLock { (_reply, _finish, _error, _hold) }
        let id = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                if hold {
                    continuation.yield(.delta("The meeting"))
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                            let resumeNow = self.lock.withLock { () -> Bool in
                                guard self._hold else { return true }
                                self.release = waiter
                                return false
                            }
                            if resumeNow { waiter.resume() }
                        }
                    } onCancel: {
                        self.releaseHold()
                    }
                    if Task.isCancelled { continuation.finish(); return }
                }
                if let error { continuation.finish(throwing: error); return }
                continuation.yield(.delta(reply))
                continuation.yield(.completed(GenerationResult(
                    text: reply, provider: id, model: request.model, latency: .milliseconds(5), finishReason: finish)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class FakeSelection: SessionSelection {
    var captureResult: Result<Capture, CaptureRefusal>
    var replaceOutcome: ReplaceOutcome = .replaced
    /// Answers for successive copies; true when the list runs out.
    var copyAnswers: [Bool] = []
    var strategyValue = AppStrategy()
    private(set) var captures = 0
    private(set) var snapshots = 0
    private(set) var replaced: [(text: String, pasteAnyway: Bool)] = []
    private(set) var copied: [String] = []
    private var clipboardWaiters: [CheckedContinuation<Void, Never>] = []

    init(capture: Capture) { captureResult = .success(capture) }

    func capture(app: AppIdentity, hotKeyCode: CGKeyCode?) async -> Result<Capture, CaptureRefusal> {
        captures += 1
        return captureResult
    }
    func prepareSnapshot() async { snapshots += 1 }
    func replace(_ text: String, capture: Capture, pasteAnyway: Bool) async -> ReplaceOutcome {
        replaced.append((text, pasteAnyway))
        return replaceOutcome
    }
    func copy(_ text: String) async -> Bool {
        let answer = copyAnswers.isEmpty ? true : copyAnswers.removeFirst()
        if answer { copied.append(text) }
        return answer
    }
    func clipboardReadFinished() async {
        await withCheckedContinuation { clipboardWaiters.append($0) }
    }
    func strategy(for bundleIdentifier: String?) -> AppStrategy { strategyValue }

    var isWaitingForClipboard: Bool { !clipboardWaiters.isEmpty }
    func finishClipboardRead() {
        let waiters = clipboardWaiters
        clipboardWaiters = []
        waiters.forEach { $0.resume() }
    }
}

final class FakeCatalog: ModelCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptors: [ModelSelection: ModelDescriptor] = [:]
    private var _alternatives: [ModelCandidate] = []

    var descriptors: [ModelSelection: ModelDescriptor] {
        get { lock.withLock { _descriptors } }
        set { lock.withLock { _descriptors = newValue } }
    }
    var alternativeModels: [ModelCandidate] {
        get { lock.withLock { _alternatives } }
        set { lock.withLock { _alternatives = newValue } }
    }

    func descriptor(for selection: ModelSelection) async -> ModelDescriptor? { descriptors[selection] }
    func alternatives() async -> [ModelCandidate] { alternativeModels }
}

@MainActor
final class FakeExampleSink: ExampleSink {
    let profiles: ProfileStore
    private(set) var saved: [(example: Example, replacing: UUID?)] = []
    private(set) var neutralizedCount = 0

    init(profiles: ProfileStore) { self.profiles = profiles }

    func save(_ example: Example, to profileID: UUID, replacing: UUID?) throws -> Profile {
        saved.append((example, replacing))
        guard var profile = try profiles.profile(profileID) else { throw ProfileStoreError.notFound(profileID) }
        if let replacing { profile.examples.removeAll { $0.id == replacing } }
        profile.examples.append(example)
        return try profiles.save(profile)
    }

    func neutralized(_ example: Example) -> Example {
        neutralizedCount += 1
        return Example(id: example.id, input: "Write to person@example.com", output: "Write to person@example.com.")
    }
}
