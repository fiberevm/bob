import Foundation

/// A bounded, bidirectional pipe to an installed executable. Pipe reads never
/// block the main actor; cancellation terminates the owned child process.
public final class JSONLineProcess: @unchecked Sendable {
    public let messages: AsyncThrowingStream<[String: Any], Error>
    private let continuation: AsyncThrowingStream<[String: Any], Error>.Continuation
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let control = ProcessControl()
    private let writeLock = NSLock()
    private var inputClosed = false
    private let diagnostics = DiagnosticBuffer()

    public init(executable: URL, arguments: [String], directory: URL?, environment: [String: String]) throws {
        let pair = AsyncThrowingStream<[String: Any], Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        messages = pair.stream; continuation = pair.continuation
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        control.attach(process)
        try process.run()
        control.didStart()
        continuation.onTermination = { [weak self] _ in self?.stop() }
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { stderrDone.leave() }
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { return }
                diagnostics.append(data)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var pending = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        let frame = Data(pending[..<end])
                        pending.removeSubrange(...end)
                        if frame.isEmpty { continue }
                        guard frame.count <= 8 * 1024 * 1024,
                              let value = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                            throw BobError.message("Claude Code returned an invalid stream frame.")
                        }
                        if case .dropped = continuation.yield(value) {
                            throw BobError.message("Claude Code produced too much buffered output. The run was stopped.")
                        }
                    }
                    guard pending.count <= 8 * 1024 * 1024 else { throw BobError.message("Claude Code stream frame exceeded 8 MB.") }
                }
                process.waitUntilExit(); stderrDone.wait()
                control.finish()
                guard pending.isEmpty else { throw BobError.message("Claude Code exited with an incomplete stream frame.") }
                if process.terminationStatus != 0 {
                    throw BobError.message("Claude Code exited (\(process.terminationStatus)). \(diagnostics.text)")
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
                stop()
            }
        }
    }
    public func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        writeLock.lock(); defer { writeLock.unlock() }
        guard !inputClosed else { throw BobError.message("Claude Code input is closed.") }
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    public func closeInput() {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !inputClosed else { return }
        inputClosed = true
        try? input.fileHandleForWriting.close()
    }
    public func finish() async throws {
        closeInput()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { stop(); throw BobError.message("Claude Code did not finish saving its session. Inspect the chat before continuing.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard process.terminationStatus == 0 else { throw BobError.message("Claude Code exited (\(process.terminationStatus)). \(diagnostics.text)") }
    }
    public func stop() { closeInput(); control.cancel() }
    public func fail(_ error: Error) { continuation.finish(throwing: error); stop() }
}

private final class DiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk); data = Data(data.suffix(16 * 1024)) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
