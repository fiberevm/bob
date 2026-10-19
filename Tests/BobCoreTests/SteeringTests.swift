import XCTest
@testable import Bob
@testable import BobCore

private actor SteeringModel: ModelTransport {
    private(set) var inputs: [[ModelMessage]] = []
    private(set) var interrupted = false
    let proposesWrite: Bool
    init(proposesWrite: Bool = false) { self.proposesWrite = proposesWrite }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        inputs.append(messages)
        if messages.filter({ $0.role == "user" }).count == 1 {
            if proposesWrite { return .init(role: "assistant", toolCalls: [.init(id: "stale-write", name: "write_file", arguments: #"{"path":"old.txt","content":"stale"}"#)]) }
            await onText("Original work")
            do { try await Task.sleep(for: .seconds(30)) }
            catch { interrupted = true }
            // Deliberately ignore cancellation and return an old tool proposal.
            return .init(role: "assistant", toolCalls: [.init(id: "stale-write", name: "write_file", arguments: #"{"path":"old.txt","content":"stale"}"#)])
        }
        return .init(role: "assistant", text: "Updated: " + (messages.last { $0.role == "user" }?.text ?? ""))
    }
}

private actor HeldToolModel: ModelTransport {
    private var first = true
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        if first {
            first = false
            return .init(role: "assistant", toolCalls: [.init(id: "running", name: "effect", arguments: "{}"), .init(id: "stale", name: "effect", arguments: "{}")])
        }
        return .init(role: "assistant", text: messages.last { $0.role == "user" }?.text ?? "")
    }
}

private actor HeldTool {
    private(set) var calls: [String] = []
    private var released = false
    func release() { released = true }
    func run(_ call: ToolCall) async throws -> ToolResult {
        calls.append(call.id)
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        return .init(text: "Completed once")
    }
}

private actor SteeringReview: ToolSafetyReviewing {
    private(set) var started = false
    private(set) var cancelled = false
    func review(_ call: ToolCall, definition: ToolDefinition, context: ToolReviewContext) async throws -> ToolSafetyAssessment {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        return .init(risk: .low, reason: "Late")
    }
}

private actor SteeringContextReview: ToolSafetyReviewing {
    private(set) var contexts: [ToolReviewContext] = []
    func review(_ call: ToolCall, definition: ToolDefinition, context: ToolReviewContext) async throws -> ToolSafetyAssessment {
        contexts.append(context)
        return .init(risk: .low, reason: "Fixture")
    }
}

private actor SteeringReadModel: ModelTransport {
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        if messages.filter({ $0.role == "user" }).count == 1 {
            await onText("Working")
            try await Task.sleep(for: .seconds(30))
        }
        if !messages.contains(where: { $0.toolCallID == "new-read" }) {
            return .init(role: "assistant", toolCalls: [.init(id: "new-read", name: "read_file", arguments: #"{"path":"README.md"}"#)])
        }
        return .init(role: "assistant", text: "Read the new target")
    }
}

@MainActor final class SteeringTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-steering-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for steering", file: file, line: line)
    }
    private func store(_ root: URL) -> AppStore {
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        store.newSession(provider: .compatible); store.setModel("fixture")
        return store
    }

    func testMessagesDuringGenerationSteerTheSameRunInOrderAndSurviveReopen() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = store(root), model = SteeringModel()
        defer { store.shutdown() }
        store.draft = "Inspect the project"
        store.send(transport: model, reviewer: FixtureToolSafetyReviewer())
        let session = try XCTUnwrap(store.selectedID)
        try await waitUntil { store.selected?.messages.last?.text == "Original work" }
        store.draft = "Focus on the parser"
        store.send()
        store.draft = "Use the existing parser API"
        store.send()
        XCTAssertEqual(store.selectedID, session)
        XCTAssertEqual(store.runningSessionIDs, [session])
        XCTAssertEqual(store.draft, "")
        try await waitUntil { !store.isRunning }
        let prompts = ["Inspect the project", "Focus on the parser", "Use the existing parser API"]
        XCTAssertEqual(store.selected?.messages.filter { $0.role == .user }.map(\.text), prompts)
        XCTAssertEqual(store.selected?.turns.filter { $0.role == "user" }.map(\.text), prompts)
        XCTAssertEqual(store.selected?.messages.last?.text, "Updated: Use the existing parser API")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old.txt").path))
        let interrupted = await model.interrupted
        XCTAssertTrue(interrupted)
        store.saveNow()
        let reopened = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { reopened.shutdown() }
        reopened.select(session)
        XCTAssertEqual(reopened.selected?.messages.filter { $0.role == .user }.map(\.text), prompts)
        XCTAssertEqual(reopened.selected?.turns.filter { $0.role == "user" }.map(\.text), prompts)
    }

    func testSteeringDismissesPendingApprovalAndCannotExecuteItsStaleCallback() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = store(root), model = SteeringModel(proposesWrite: true)
        defer { store.shutdown() }
        store.draft = "Write old.txt"
        store.send(transport: model, reviewer: FixtureToolSafetyReviewer())
        try await waitUntil { store.approval != nil }
        let stale = try XCTUnwrap(store.approval)
        store.draft = "Do not write anything; explain the approach"
        store.send()
        XCTAssertNil(store.approval)
        stale.resolve(true)
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.selected?.messages.last?.text, "Updated: Do not write anything; explain the approach")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old.txt").path))
        XCTAssertEqual(ConversationHistory.repaired(store.selected!.turns), store.selected!.turns)
    }

    func testSteeringCancelsAnOldReviewBeforeItCanExecute() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = store(root), review = SteeringReview()
        defer { store.shutdown() }
        store.draft = "Write old.txt"
        store.send(transport: SteeringModel(proposesWrite: true), reviewer: review)
        try await waitUntil { await review.started }
        store.draft = "Do not edit any files"
        store.send()
        try await waitUntil { !store.isRunning }
        let cancelled = await review.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertEqual(store.selected?.messages.last?.text, "Updated: Do not edit any files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old.txt").path))
    }

    func testAnExecutingToolFinishesOnceAndRemainingOldProposalsAreSkipped() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turn.jsonl")
        let input = AgentInput(), tool = HeldTool(), journal = TurnJournal(url: url)
        let registry = ToolRegistry(definitions: [.init(name: "effect", description: "Fixture", parameters: [:])], perform: { try await tool.run($0) })
        let task = Task {
            try await AgentRuntime().run(runID: UUID(), messages: [.init(role: "user", text: "Original")], system: "", client: HeldToolModel(), tools: registry, journal: journal, input: input) { _ in }
        }
        try await waitUntil { await tool.calls == ["running"] }
        input.send("Change direction")
        try await Task.sleep(for: .milliseconds(30))
        let during = await tool.calls
        XCTAssertEqual(during, ["running"])
        await tool.release()
        let history = try await task.value
        let after = await tool.calls
        XCTAssertEqual(after, ["running"])
        XCTAssertEqual(history.last?.text, "Change direction")
        XCTAssertEqual(history.first { $0.toolCallID == "running" }?.text, "Completed once")
        XCTAssertEqual(history.first { $0.toolCallID == "stale" }?.text, "Aborted before execution.")
        XCTAssertEqual(ConversationHistory.repaired(history), history)
        XCTAssertEqual(try TurnJournal.recover(from: url)?.history, history)
    }

    func testSteeringUpdatesAreTrustedOriginalAuthorizationForSubsequentReviews() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try "Fixture".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let input = AgentInput(), review = SteeringContextReview(), harness = AgentHarness(reviewer: review)
        harness.onEvent = { event in if case .text("Working") = event { input.send("Read README.md; do not edit it") } }
        let history = try await harness.run(configuration: .init(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: ""),
            messages: [.init(role: "user", text: "Inspect the project")], files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")),
            project: root.path, transport: SteeringReadModel(), input: input)
        let contexts = await review.contexts
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.userMessages, ["Inspect the project", "Read README.md; do not edit it"])
        XCTAssertEqual(history.last?.text, "Read the new target")
    }

    func testSteeringOneChatDoesNotInterruptAnotherAndStopStillWorks() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = store(root), firstModel = SteeringModel(), otherModel = SteeringModel()
        defer { store.shutdown() }
        let first = try XCTUnwrap(store.selectedID)
        store.draft = "First task"; store.send(transport: firstModel, reviewer: FixtureToolSafetyReviewer())
        try await waitUntil { store.selected?.messages.last?.text == "Original work" }
        store.newSession(provider: .compatible); store.setModel("fixture")
        let other = try XCTUnwrap(store.selectedID)
        store.draft = "Other task"; store.send(transport: otherModel, reviewer: FixtureToolSafetyReviewer())
        try await waitUntil { store.selected?.messages.last?.text == "Original work" }
        store.select(first)
        store.draft = "Focus on the parser"; store.send()
        try await waitUntil { !store.runningSessionIDs.contains(first) }
        XCTAssertEqual(store.runningSessionIDs, [other])
        let otherInputs = await otherModel.inputs
        XCTAssertEqual(otherInputs.count, 1)
        XCTAssertEqual(otherInputs.first?.filter { $0.role == "user" }.map(\.text), ["Other task"])
        store.select(other)
        store.draft = "Use the existing API"; store.send()
        store.stop()
        try await waitUntil { store.runningSessionIDs.isEmpty }
        XCTAssertEqual(store.selected?.messages.last?.text, "Stopped. Send a follow-up to continue.")
        XCTAssertEqual(store.selected?.turns.filter { $0.role == "user" }.map(\.text), ["Other task", "Use the existing API"])
    }

    func testCrashRecoveryKeepsSteeringThatArrivedDuringAnUnfinishedTool() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = store(root)
        let original = Message(role: .user, text: "Original task"), runID = UUID()
        let update = Message(role: .user, text: "Do not repeat the command", isSteering: true)
        let call = ToolCall(id: "unfinished", name: "run_command", arguments: #"{"command":"fixture"}"#)
        let history = [ModelMessage(role: "user", text: original.text, userMessageID: original.id), .init(role: "assistant", text: "Working", toolCalls: [call])]
        var session = try XCTUnwrap(store.selected)
        session.messages = [original, Message(role: .assistant, text: "Working", id: runID), update]
        session.turns = history
        store.sessions = [session]; store.selectedID = session.id; store.saveNow()
        let journal = TurnJournal(url: store.dataDirectory.appendingPathComponent("turns/\(session.id.uuidString).jsonl"))
        try await journal.begin(runID: runID, history: history)
        try await journal.started(call)
        let reopened = AppStore(projectPath: root.path, storageDirectory: store.dataDirectory)
        defer { store.shutdown(); reopened.shutdown() }
        XCTAssertEqual(reopened.selected?.messages.filter { $0.role == .user }.map(\.id), [original.id, update.id])
        XCTAssertEqual(reopened.selected?.turns.filter { $0.role == "user" }.map(\.text), [original.text, update.text])
        XCTAssertTrue(reopened.selected?.turns.contains { $0.toolCallID == call.id && $0.text.contains("may have completed") } == true)
    }
}
