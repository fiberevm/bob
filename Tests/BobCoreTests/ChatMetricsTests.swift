import XCTest
@testable import Bob
@testable import BobCore

private actor MetricsModel: ModelTransport {
    let usage: ModelUsage
    private var released = false
    init(input: Int, output: Int) { usage = .init(inputTokens: input, outputTokens: output) }
    func release() { released = true }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        await onText("Working")
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        return .init(role: "assistant", text: "Working: done", usage: usage)
    }
}

private actor CompactionMetricsModel: ModelTransport {
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        if system.contains("Summarize this coding conversation") {
            return .init(role: "assistant", text: "Previous work was inspected. Continue the latest task.", usage: .init(inputTokens: 1200, outputTokens: 100))
        }
        return .init(role: "assistant", text: "Done", usage: .init(inputTokens: 2000, outputTokens: 200))
    }
}

private actor TitleMetricsModel: ModelTransport {
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        .init(role: "assistant", text: "Inspect the parser", usage: .init(inputTokens: 80, outputTokens: 5))
    }
}

private actor MetricsEvents {
    private(set) var records: [String: ModelUsage] = [:]
    private(set) var context: ContextUsage?
    func receive(_ event: RuntimeEvent) {
        if case .usage(let record) = event { records[record.id] = record.usage }
        if case .context(let value) = event { context = value }
    }
}

final class ChatMetricsCoreTests: XCTestCase {
    func testDefaultContextBudgetIs300ThousandTokens() {
        let manager = ContextManager()
        XCTAssertEqual(manager.inputTokenBudget, 300_000)
        let history = [ModelMessage(role: "assistant", text: "Previous work", usage: .init(inputTokens: 100_000, outputTokens: 100))]
        let context = manager.usage(history)
        XCTAssertEqual(context.budget, 300_000)
        XCTAssertEqual(context.tokens, 100_100)
        XCTAssertEqual(context.source, .localBudget)
        XCTAssertLessThan(context.fraction ?? 1, 1)
    }

    func testTitleGenerationReportsItsUsageWithoutEnteringChatContext() async throws {
        let events = MetricsEvents()
        let title = try await ConversationTitle.generate(for: "Inspect the parser", configuration: .init(provider: .compatible, model: "fixture", baseURL: "http://localhost", token: ""), transport: TitleMetricsModel(), onUsage: { record in
            await events.receive(.usage(record))
        })
        let records = await events.records
        let context = await events.context
        XCTAssertEqual(title, "Inspect the parser")
        XCTAssertEqual(records.values.first, .init(inputTokens: 80, outputTokens: 5))
        XCTAssertNil(context)
    }

    func testTotalsSurviveCompactionAndRepeatedReportsDoNotDoubleCount() throws {
        var chat = Session(projectPath: "/project")
        chat.turns = [.init(role: "assistant", text: "Old response", usage: .init(inputTokens: 100, outputTokens: 20))]
        chat.migrateTokenUsage()
        chat.recordTokenUsage(.init(id: "request", usage: .init(inputTokens: 200, outputTokens: 30)))
        chat.recordTokenUsage(.init(id: "request", usage: .init(inputTokens: 200, outputTokens: 40)))
        chat.turns = [.init(role: "user", text: "Compacted summary")]
        XCTAssertEqual(chat.totalTokenUsage, .init(inputTokens: 300, outputTokens: 60))
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(chat))
        XCTAssertEqual(restored.totalTokenUsage, chat.totalTokenUsage)
        XCTAssertEqual(Session(projectPath: "/new").totalTokenUsage, .zero)
        var unknown = Session(projectPath: "/unknown")
        unknown.turns = [.init(role: "assistant", text: "No reported usage")]
        XCTAssertNil(unknown.totalTokenUsage)
    }

    func testContextUsesLatestRequestAndCountsInstructionsOnlyOnce() {
        let manager = ContextManager(inputTokenBudget: 8000)
        let history = [ModelMessage(role: "assistant", text: "Short", usage: .init(inputTokens: 6000, outputTokens: 100))]
        let context = manager.usage(history, system: String(repeating: "x", count: 900))
        XCTAssertEqual(context.tokens, 6100)
        XCTAssertEqual(context.fraction, 0.7625)
        XCTAssertEqual(context.source, .localBudget)
        XCTAssertTrue(context.isEstimated)
        let withTool = history + [.init(role: "tool", text: String(repeating: "result", count: 100), toolCallID: "tool")]
        XCTAssertGreaterThan(manager.usage(withTool).tokens, context.tokens)
        XCTAssertEqual(manager.usage([]).tokens, 0)
        XCTAssertEqual(ContextUsage(tokens: 9000, budget: 8000, isEstimated: false, source: .provider).fraction, 1)
        XCTAssertNil(ContextUsage(tokens: 1000, budget: nil, isEstimated: true, source: .provider).fraction)
    }

    func testCompactionUsageIsRecordedSeparatelyAndJournalCheckpointsRetainIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-metrics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TurnJournal(url: root.appendingPathComponent("turn.jsonl")), events = MetricsEvents()
        let runID = UUID()
        let history = [ModelMessage(role: "user", text: String(repeating: "Previous task details. ", count: 1200)), .init(role: "user", text: "Continue")]
        let result = try await AgentRuntime().run(runID: runID, messages: history, system: "Test", client: CompactionMetricsModel(),
            tools: ToolRegistry(definitions: [], execute: { _ in "" }), journal: journal, context: ContextManager(inputTokenBudget: 4000)) { event in
                await events.receive(event)
            }
        let records = await events.records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.values.reduce(ModelUsage.zero) { $0.adding($1) }, .init(inputTokens: 3200, outputTokens: 300))
        let latestContext = await events.context
        XCTAssertEqual(latestContext?.tokens, 2200)
        XCTAssertTrue(result.first?.text.contains("summary") == true)
        try await journal.begin(runID: runID, history: result)
        try await journal.finish()
        let recovered = try XCTUnwrap(TurnJournal.recover(from: root.appendingPathComponent("turn.jsonl")))
        XCTAssertEqual(recovered.usageRecords, records)
    }

    func testUsageWrittenBeforeHistorySurvivesInterruptedJournalRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-metrics-crash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TurnJournal(url: root.appendingPathComponent("turn.jsonl"))
        try await journal.begin(runID: UUID(), history: [.init(role: "user", text: "Work")])
        try await journal.recordUsage(.init(id: "completed-request", usage: .init(inputTokens: 500, outputTokens: 50)))
        let recovered = try XCTUnwrap(TurnJournal.recover(from: root.appendingPathComponent("turn.jsonl")))
        XCTAssertTrue(recovered.interrupted)
        XCTAssertEqual(recovered.usageRecords["completed-request"], .init(inputTokens: 500, outputTokens: 50))
    }

    func testClaudeUsageIncludesCachedInputWithoutAddingItToOutput() {
        XCTAssertEqual(ModelUsage.claude(["input_tokens": 100, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 300, "output_tokens": 40]),
                       .init(inputTokens: 600, outputTokens: 40))
        XCTAssertNil(ModelUsage.claude([:]))
    }
}

@MainActor final class ChatMetricsSelectionTests: XCTestCase {
    func testSelectedChatMetricsStayIndependentWhileOtherChatsFinishAndAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-selected-metrics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage)
        defer { store.shutdown() }
        let firstModel = MetricsModel(input: 1000, output: 20), secondModel = MetricsModel(input: 4000, output: 70)
        store.newSession(provider: .compatible); store.setModel("first-model"); store.draft = "First task"
        store.send(transport: firstModel, reviewer: FixtureToolSafetyReviewer())
        let first = try XCTUnwrap(store.selectedID)
        store.newSession(provider: .compatible); store.setModel("second-model"); store.draft = "Second task"
        store.send(transport: secondModel, reviewer: FixtureToolSafetyReviewer())
        let second = try XCTUnwrap(store.selectedID)
        store.newSession()
        let idle = try XCTUnwrap(store.selectedID)
        XCTAssertNil(store.selectedChatActivity)
        XCTAssertEqual(store.selected?.totalTokenUsage, .zero)
        await firstModel.release()
        try await wait { !store.runningSessionIDs.contains(first) }
        XCTAssertEqual(store.selectedID, idle)
        XCTAssertEqual(store.selected?.totalTokenUsage, .zero)
        store.select(first)
        XCTAssertEqual(store.selected?.totalTokenUsage, .init(inputTokens: 1000, outputTokens: 20))
        XCTAssertNil(store.selectedChatActivity)
        let firstContext = store.selectedContextUsage
        await secondModel.release()
        try await wait { store.runningSessionIDs.isEmpty }
        XCTAssertEqual(store.selectedContextUsage, firstContext)
        store.select(second)
        XCTAssertEqual(store.selectedModelID, "second-model")
        XCTAssertEqual(store.selected?.totalTokenUsage, .init(inputTokens: 4000, outputTokens: 70))
        store.saveNow()
        let restored = AppStore(projectPath: root.path, storageDirectory: storage)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.selected?.totalTokenUsage, store.selected?.totalTokenUsage)
        restored.select(first)
        XCTAssertEqual(restored.selected?.totalTokenUsage, .init(inputTokens: 1000, outputTokens: 20))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for chat metrics")
    }
}
