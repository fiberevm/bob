import Foundation

/// Per-run user input, shared by the UI, model loop, and tool review boundary.
/// Only model generation and review are interrupted; running effects finish.
public final class AgentInput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ModelMessage] = []
    private var submitted: [String] = []
    private var interrupt: (id: UUID, cancel: @Sendable () -> Void)?
    public let notifications: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    public init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        notifications = stream.stream; signal = stream.continuation
    }
    public func send(_ text: String, id: UUID = UUID(), images: [ModelImage] = []) {
        lock.lock()
        pending.append(.init(role: "user", text: text, images: images, userMessageID: id)); submitted.append(text)
        let cancel = interrupt?.cancel
        lock.unlock()
        cancel?(); signal.yield(())
    }
    /// Explicit form answers are trusted user input, not steering messages.
    public func recordAnswer(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        submitted.append(text)
    }
    public var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }
    public var userMessages: [String] { lock.lock(); defer { lock.unlock() }; return submitted }
    public func takePending() -> [ModelMessage] {
        lock.lock(); defer { lock.unlock() }
        let messages = pending; pending = []; return messages
    }
    public func checkPending() throws { if hasPending { throw AgentSteered() } }

    public func interruptible<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let task = Task { try await operation() }, id = UUID()
        register(id: id, cancel: { task.cancel() })
        defer { unregister(id: id) }
        return try await withTaskCancellationHandler(operation: {
            do {
                let result = try await task.value
                try Task.checkCancellation()
                try checkPending()
                return result
            } catch {
                try Task.checkCancellation()
                try checkPending()
                throw error
            }
        }, onCancel: { task.cancel() })
    }
    private func register(id: UUID, cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        interrupt = (id, cancel)
        let shouldCancel = !pending.isEmpty
        lock.unlock()
        if shouldCancel { cancel() }
    }
    private func unregister(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if interrupt?.id == id { interrupt = nil }
    }
}

public struct AgentSteered: Error, Sendable {
    public init() {}
}
