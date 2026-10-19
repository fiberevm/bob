import Foundation
import Darwin

public struct DecisionQuestion: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case choice, noul, score }
    public let id: String
    public let type: Kind
    public let instructions: String
    public let choices: [String: String]?
    public let levels: [String]?

    public init(id: String, type: Kind, instructions: String, choices: [String: String]? = nil, levels: [String]? = nil) {
        self.id = id; self.type = type; self.instructions = instructions; self.choices = choices; self.levels = levels
    }
    var optionIDs: Set<String> {
        switch type {
        case .choice: return Set((choices ?? [:]).keys)
        case .noul: return ["true", "false"]
        case .score: return Set((levels ?? []).indices.map(String.init))
        }
    }
}

public struct DecisionRequest: Codable, Sendable {
    public let state: String
    public let questions: [DecisionQuestion]
    public let maxTokens: Int
    enum CodingKeys: String, CodingKey { case state, questions; case maxTokens = "max_tokens" }

    public init(state: String, questions: [DecisionQuestion], maxTokens: Int = 4096) {
        self.state = state; self.questions = questions; self.maxTokens = maxTokens
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state)
        questions = try values.decode([DecisionQuestion].self, forKey: .questions)
        maxTokens = try values.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 4096
    }
    public func validate() throws {
        guard (1...16384).contains(maxTokens), !questions.isEmpty, questions.count <= 32,
              Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ !$0.id.isEmpty && !$0.optionIDs.isEmpty && $0.optionIDs.count <= 128 && !$0.optionIDs.contains("") }) else {
            throw BobError.message("Use 1–32 unique decision questions, 1–128 options per question, and a token limit from 1 to 16384.")
        }
    }
}

public struct DecisionResponse: Codable, Sendable {
    public struct Answer: Codable, Sendable {
        public let id: String
        public let probabilities: [String: Double]
        public let selectedOption: String
        public let confidence: Double
        public let score: Double?
        public let noul: Double?
        enum CodingKeys: String, CodingKey {
            case id, probabilities, confidence, score, noul
            case selectedOption = "selected_option"
        }
    }
    public let decisions: [Answer]
    public let inputTokens: Int
    public let loadSeconds: Double
    public let decisionSeconds: Double
    enum CodingKeys: String, CodingKey {
        case decisions
        case inputTokens = "input_tokens", loadSeconds = "load_seconds", decisionSeconds = "decision_seconds"
    }

    func validate(for request: DecisionRequest) throws {
        guard decisions.map(\.id) == request.questions.map(\.id), (1...request.maxTokens).contains(inputTokens),
              loadSeconds.isFinite, loadSeconds >= 0, decisionSeconds.isFinite, decisionSeconds >= 0 else {
            throw BobError.message("The local decision model returned an invalid response.")
        }
        for (answer, question) in zip(decisions, request.questions) {
            let values = answer.probabilities
            guard Set(values.keys) == question.optionIDs,
                  values.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(values.values.reduce(0, +) - 1) < 0.001,
                  let selected = values[answer.selectedOption], abs(selected - answer.confidence) < 0.0001,
                  selected >= (values.values.max() ?? 0) - 0.0001 else {
                throw BobError.message("The local decision model returned invalid probabilities.")
            }
            switch question.type {
            case .noul:
                guard let probability = answer.noul, abs(probability - values["true"]!) < 0.0001 else {
                    throw BobError.message("The local decision model returned an invalid boolean probability.")
                }
            case .score:
                let expected = values.reduce(0.0) { $0 + Double($1.key)! * $1.value }
                guard let score = answer.score, abs(score - expected) < 0.001 else {
                    throw BobError.message("The local decision model returned an invalid score.")
                }
            case .choice: break
            }
        }
    }
}

/// A complete request was rejected before inference. The worker remains usable.
public struct DecisionInputLimitError: LocalizedError, Sendable {
    public let requiredTokens: Int
    public let maximumTokens: Int
    public var errorDescription: String? {
        "Request requires \(requiredTokens) tokens; maximum is \(maximumTokens). State is never silently truncated."
    }
    init?(workerMessage: String) {
        let expression = try! NSRegularExpression(pattern: #"^Request requires (\d+) tokens; maximum is (\d+)\. State is never silently truncated\.$"#)
        let text = workerMessage as NSString
        guard let match = expression.firstMatch(in: workerMessage, range: NSRange(location: 0, length: text.length)),
              let required = Int(text.substring(with: match.range(at: 1))),
              let maximum = Int(text.substring(with: match.range(at: 2))),
              (1...16384).contains(maximum), required > maximum else { return nil }
        requiredTokens = required; maximumTokens = maximum
    }
}

/// Serial, persistent Swift/Metal worker. No network or tool execution occurs.
/// Shares one model across callers; idle weights are released after 60 seconds.
public final class LocalDecisionModel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bob.local-decisions", qos: .userInitiated)
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let idleTimeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var idleWork: DispatchWorkItem?

    public init(executable: URL, modelDirectory: URL, timeout: TimeInterval = 120, idleTimeout: TimeInterval = 60) {
        self.executable = executable; self.arguments = [modelDirectory.path]
        self.timeout = timeout; self.idleTimeout = idleTimeout
    }
    deinit { if let process, process.isRunning { process.terminate() } }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        try request.validate()
        let control = DecisionOperation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.idleWork?.cancel()
                    defer { self.scheduleUnload() }
                    var usedWorker = false
                    do {
                        try control.check()
                        try self.start()
                        usedWorker = true
                        control.attach(self.process!)
                        let deadline = DispatchWorkItem { control.stop(timedOut: true) }
                        DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout, execute: deadline)
                        defer { deadline.cancel(); control.detach() }
                        var data = try JSONEncoder().encode(request)
                        guard data.count < 1024 * 1024 else { throw BobError.message("Decision request exceeds 1 MB.") }
                        data.append(10)
                        try self.input!.write(contentsOf: data)
                        var response = Data()
                        while response.last != 10 {
                            let chunk = try self.readChunk()
                            guard !chunk.isEmpty else {
                                throw BobError.message("Local decision worker stopped before returning an answer.")
                            }
                            response.append(chunk)
                            guard response.count <= 1024 * 1024 else { throw BobError.message("Decision response exceeds 1 MB.") }
                        }
                        try control.check()
                        if let failure = try? JSONDecoder().decode(WorkerFailure.self, from: response) {
                            if let limit = DecisionInputLimitError(workerMessage: failure.error) { throw limit }
                            throw BobError.message(failure.error)
                        }
                        let result = try JSONDecoder().decode(DecisionResponse.self, from: response)
                        try result.validate(for: request)
                        continuation.resume(returning: result)
                    } catch {
                        // A caller cancelled while queued never owned the
                        // worker and must not discard another caller's model.
                        // A token-limit rejection consumed a complete response
                        // and never began inference; retry on the loaded model.
                        if usedWorker && !(error is DecisionInputLimitError) { self.stop() }
                        do { try control.check(); continuation.resume(throwing: error) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }, onCancel: { control.stop(timedOut: false) })
    }

    public func unload() { queue.async { self.stop() } }

    private func start() throws {
        if process?.isRunning == true { return }
        stop()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BobError.message("Set up Clef-flash with make decisions first.")
        }
        let worker = Process(), stdin = Pipe(), stdout = Pipe()
        worker.executableURL = executable; worker.arguments = arguments
        worker.standardInput = stdin; worker.standardOutput = stdout
        // Only the structured protocol is accepted on stdout. Diagnostics cannot
        // fill an unread stderr pipe or become an answer.
        worker.standardError = FileHandle.nullDevice
        worker.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        try worker.run()
        process = worker; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }
    private func scheduleUnload() {
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        idleWork = work
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }
    private func readChunk() throws -> Data {
        // FileHandle.read(upToCount:) may wait for the entire requested count
        // on a pipe. A POSIX read returns as soon as a worker writes its line.
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(output!.fileDescriptor, &buffer, buffer.count)
            if count >= 0 { return Data(buffer.prefix(count)) }
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }
    private func stop() {
        try? input?.close(); try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil
    }
    private struct WorkerFailure: Decodable { let error: String }
}

private final class DecisionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled && process.isRunning { process.terminate() }
    }
    func detach() { lock.lock(); process = nil; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if timedOut { throw BobError.message("Local decision timed out. Try a shorter state or fewer questions.") }
        if cancelled { throw CancellationError() }
    }
    func stop(timedOut: Bool) {
        lock.lock()
        cancelled = true; self.timedOut = self.timedOut || timedOut
        let running = process
        if let running, running.isRunning { running.terminate() }
        lock.unlock()
        if let running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
}
