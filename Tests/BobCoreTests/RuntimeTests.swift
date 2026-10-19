import XCTest
@testable import BobCore

private actor SummaryModel: ModelTransport {
    private(set) var input: [ModelMessage] = []
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        input = messages
        XCTAssertTrue(tools.isEmpty)
        return ModelMessage(role: "assistant", text: "Completed: inspected Sources/A.swift. Pending: fix the parser and run tests. A prior command may have completed; inspect state before retrying.")
    }
}

private actor ContinuingToolModel: ModelTransport {
    private var calls = 0
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        calls += 1
        return .init(role: "assistant", toolCalls: [.init(id: "call-\(calls)", name: "inspect", arguments: "{}")])
    }
}

final class RuntimeTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testCrashRecoveryPreservesResultsAndMarksUncertainCallsWithTornTail() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turn.jsonl"), journal = TurnJournal(url: url)
        let calls = ["completed", "uncertain", "queued"].map { ToolCall(id: $0, name: "run_command", arguments: "{}") }
        try await journal.begin(runID: UUID(), history: [ModelMessage(role: "user", text: "Work")])
        try await journal.append(ModelMessage(role: "assistant", toolCalls: calls))
        try await journal.started(calls[0])
        try await journal.append(ModelMessage(role: "tool", text: "Exit: 0", toolCallID: calls[0].id))
        try await journal.started(calls[1])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"kind\":".utf8)); try handle.close()
        let recovered = try XCTUnwrap(TurnJournal.recover(from: url))
        XCTAssertTrue(recovered.interrupted)
        XCTAssertEqual(recovered.history.filter { $0.role == "tool" }.count, 3)
        XCTAssertTrue(recovered.history.contains { $0.toolCallID == "completed" && $0.text == "Exit: 0" })
        XCTAssertTrue(recovered.history.contains { $0.toolCallID == "uncertain" && $0.text.contains("may have completed") })
        XCTAssertTrue(recovered.history.contains { $0.toolCallID == "queued" && $0.text.contains("before execution") })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
    func testCorruptCompleteJournalRecordIsReported() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turn.jsonl")
        try Data("invalid\n".utf8).write(to: url)
        XCTAssertThrowsError(try TurnJournal.recover(from: url))
    }
    func testContextCompactionKeepsLatestPromptAndCompleteToolGroupsWithinBudget() async throws {
        let context = ContextManager(inputTokenBudget: 4000), model = SummaryModel()
        let history = [ModelMessage(role: "user", text: "Old task"), ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "old", name: "read_file", arguments: "{}")]), ModelMessage(role: "tool", text: String(repeating: "old output ", count: 8000), toolCallID: "old"), ModelMessage(role: "user", text: "Fix the parser"), ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "recent", name: "read_file", arguments: "{}")]), ModelMessage(role: "tool", text: "current parser", toolCallID: "recent")]
        let replacement = try await context.prepare(history, system: "Test", tools: [], client: model, onCompact: {})
        XCTAssertTrue(replacement.contains { $0.text == "Fix the parser" })
        XCTAssertTrue(replacement.first?.text.contains("Earlier conversation summary") == true)
        XCTAssertEqual(ConversationHistory.repaired(replacement), replacement)
        XCTAssertLessThan(context.estimatedTokens(replacement), 3500)
        let input = await model.input
        XCTAssertLessThan(input[0].text.utf8.count, 12_000)
    }
    func testProviderUsageCanTriggerCompactionEvenWhenLocalEstimateIsSmall() async throws {
        let model = SummaryModel()
        let history = [ModelMessage(role: "user", text: "Continue"), ModelMessage(role: "assistant", text: "Opaque reasoning", usage: ModelUsage(inputTokens: 30_000, outputTokens: 100))]
        let result = try await ContextManager().prepare(history, system: "Test", tools: [], client: model, onCompact: {})
        XCTAssertTrue(result.first?.text.contains("summary") == true)
    }
    func testShellEnvironmentUsesHostHomeAndToolPathWithoutSecretsOrStartupHooks() throws {
        let env = PermissionPolicy().shellEnvironment(inherited: ["OPENAI_API_KEY": "secret", "AWS_SECRET_ACCESS_KEY": "secret", "ZDOTDIR": "/secret", "DYLD_INSERT_LIBRARIES": "/secret", "LANG": "en_US.UTF-8", "PATH": "/custom/tools:/usr/bin:/bin"])
        XCTAssertNil(env["OPENAI_API_KEY"]); XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(env["ZDOTDIR"]); XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(env["TMPDIR"], FileManager.default.temporaryDirectory.path)
        XCTAssertEqual(env["PATH"], "/custom/tools:/usr/bin:/bin")
    }

    func testLongRunsRemainCancellableAfterSixteenSteps() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reached = expectation(description: "Agent reached its twentieth tool call")
        let registry = ToolRegistry(definitions: [.init(name: "inspect", description: "Fixture", parameters: [:])], perform: { call in
            if call.id == "call-20" {
                reached.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
            return .init(text: "Inspected")
        })
        let journalURL = root.appendingPathComponent("cancelled.jsonl")
        let task = Task {
            try await AgentRuntime().run(runID: UUID(), messages: [.init(role: "user", text: "Keep inspecting")], system: "", client: ContinuingToolModel(),
                tools: registry, journal: TurnJournal(url: journalURL)) { _ in }
        }
        defer { task.cancel() }
        await fulfillment(of: [reached], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let recovered = try XCTUnwrap(TurnJournal.recover(from: journalURL))
        XCTAssertEqual(recovered.history.filter { $0.role == "tool" }.count, 20)
        XCTAssertTrue(recovered.history.last?.text.contains("Interrupted during execution") == true)
        XCTAssertEqual(ConversationHistory.repaired(recovered.history), recovered.history)
    }
}
