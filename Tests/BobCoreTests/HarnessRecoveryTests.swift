import XCTest
@testable import Bob
@testable import BobCore

private actor RecoveryModel: ModelTransport {
    var responses: [ModelMessage]
    private(set) var systems: [String] = []
    init(_ responses: [ModelMessage]) { self.responses = responses }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        systems.append(system)
        guard !responses.isEmpty else { throw BobError.message("Unexpected model call") }
        return responses.removeFirst()
    }
}

@MainActor final class HarnessRecoveryTests: XCTestCase {
    private let config = ModelConfiguration(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: "")
    private func workspace() throws -> (URL, WorkspaceFiles) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")))
    }
    private func write(_ id: String, _ path: String) -> ToolCall {
        ToolCall(id: id, name: "write_file", arguments: "{\"path\":\"\(path)\",\"content\":\"agent content\"}")
    }
    func testStaleApprovalCannotAuthorizeAnotherRequest() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        var old: ApprovalRequest?, count = 0
        harness.onEvent = { event in
            guard case .approval(let request?) = event else { return }
            count += 1
            if old == nil { old = request; request.resolve(true) }
            else {
                old?.resolve(true)
                request.resolve(false)
            }
        }
        let model = RecoveryModel([ModelMessage(role: "assistant", toolCalls: [write("one", "one.txt"), write("two", "two.txt")]), ModelMessage(role: "assistant", text: "Done")])
        let history = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model)
        XCTAssertEqual(count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("two.txt").path))
        XCTAssertTrue(history.contains { $0.toolCallID == "two" && $0.text.contains("declined") })
    }
    func testStoppedBatchPersistsCompletedResultsAndRepairsRemainingCalls() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turn.jsonl"), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        let journal = TurnJournal(url: url)
        var count = 0, history: [ModelMessage] = []
        harness.onEvent = { event in
            if case .history(let value) = event { history = value }
            guard case .approval(let request?) = event else { return }
            count += 1
            if count == 1 { request.resolve(true) }
            else {
                let durable = try? TurnJournal.recover(from: url)
                XCTAssertTrue(durable?.history.contains { $0.toolCallID == "one" && $0.text.contains("Saved") } == true)
                harness.stop()
            }
        }
        let model = RecoveryModel([ModelMessage(role: "assistant", toolCalls: [write("one", "one.txt"), write("two", "two.txt"), write("three", "three.txt")])])
        do { _ = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model, journal: journal); XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(history.filter { $0.role == "tool" }.count, 3)
        XCTAssertTrue(history.contains { $0.toolCallID == "one" && $0.text.contains("Saved") })
        XCTAssertTrue(history.contains { $0.toolCallID == "three" && $0.text.contains("Aborted before") })
        XCTAssertEqual(try TurnJournal.recover(from: url)?.history, history)
    }
    func testFileCreatedDuringApprovalIsPreserved() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("new.txt"), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        harness.onEvent = { event in
            guard case .approval(let request?) = event else { return }
            try! Data("new user content".utf8).write(to: target)
            request.resolve(true)
        }
        let model = RecoveryModel([ModelMessage(role: "assistant", toolCalls: [write("one", "new.txt")]), ModelMessage(role: "assistant", text: "Done")])
        let history = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new user content")
        XCTAssertTrue(history.contains { $0.toolCallID == "one" && $0.text.contains("changed on disk") })
    }
    func testUnreadableBinaryIsNotTreatedAsMissing() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("binary"), original = Data([0, 255, 1])
        try original.write(to: target)
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        harness.onEvent = { if case .approval(let request?) = $0 { XCTFail("Must fail before approval"); request.resolve(false) } }
        let model = RecoveryModel([ModelMessage(role: "assistant", toolCalls: [write("one", "binary")]), ModelMessage(role: "assistant", text: "Done")])
        _ = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
    func testCallerCancellationClosesApprovalAndFinishesRun() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer()), ready = expectation(description: "Waiting for approval"), finished = expectation(description: "Run cancelled")
        var pending = false
        harness.onEvent = { if case .approval(let request) = $0 { pending = request != nil; if pending { ready.fulfill() } } }
        let model = RecoveryModel([ModelMessage(role: "assistant", toolCalls: [write("one", "one.txt")])])
        let task = Task {
            defer { finished.fulfill() }
            do { _ = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model); XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [ready], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        harness.stop(); await task.value
        XCTAssertFalse(pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
    }
    func testRootInstructionsAreInjectedAndNestedWritesWaitForNextSampling() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("Root rule".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("Nested rule".utf8).write(to: child.appendingPathComponent("AGENTS.md"))
        let model = RecoveryModel([
            ModelMessage(role: "assistant", toolCalls: [write("one", "child/new.txt"), write("two", "child/new.txt")]),
            ModelMessage(role: "assistant", toolCalls: [write("three", "child/new.txt")]), ModelMessage(role: "assistant", text: "Done")
        ])
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer()); var approvals = 0
        harness.onEvent = { if case .approval(let request?) = $0 { approvals += 1; request.resolve(true) } }
        let result = try await harness.run(configuration: config, messages: [ModelMessage(role: "user", text: "Write")], files: files, project: root.path, transport: model)
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(result.filter { $0.role == "tool" && $0.text.contains("Nested rule") }.count, 2)
        let systems = await model.systems
        XCTAssertTrue(systems.first?.contains("Root rule") == true)
        XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("new.txt"), encoding: .utf8), "agent content")
    }
    func testAppRestoresJournalThatIsNewerThanWorkspaceSnapshot() async throws {
        let (root, _) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("storage"), initial = AppStore(projectPath: root.path, storageDirectory: storage)
        let sessionID = try XCTUnwrap(initial.selectedID), message = Message(role: .assistant, text: "")
        initial.mutate(sessionID) { $0.messages = [Message(role: .user, text: "Write"), message]; $0.turns = [ModelMessage(role: "user", text: "Write")] }
        initial.shutdown()
        let journal = TurnJournal(url: storage.appendingPathComponent("turns").appendingPathComponent(sessionID.uuidString + ".jsonl"))
        try await journal.begin(runID: message.id, history: [ModelMessage(role: "user", text: "Write")])
        try await journal.append(ModelMessage(role: "assistant", toolCalls: [write("one", "one.txt"), write("two", "two.txt")]))
        try await journal.started(write("one", "one.txt"))
        try await journal.append(ModelMessage(role: "tool", text: "Saved one.txt", toolCallID: "one"))
        try await journal.started(write("two", "two.txt"))
        let restored = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertTrue(restored.selected?.turns.contains { $0.toolCallID == "one" && $0.text.contains("Saved") } == true)
        XCTAssertTrue(restored.selected?.turns.contains { $0.toolCallID == "two" && $0.text.contains("may have completed") } == true)
        XCTAssertFalse(restored.isRunning)
        restored.shutdown()
    }
    func testCompactionRequiresNestedInstructionsToBeDeliveredAgain() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("Nested rule".utf8).write(to: child.appendingPathComponent("AGENTS.md"))
        var count = 0
        let approvals = ApprovalCoordinator(runID: UUID()) { request in if let request { count += 1; request.resolve(true) } }
        let tools = AgentTools(files: files, project: root.path, browser: nil, reviewer: FixtureToolSafetyReviewer(), approvals: approvals, rootInstructions: "").registry
        let first = try await tools.execute(write("one", "child/new.txt"))
        XCTAssertTrue(first.contains("Nested rule"))
        await tools.beforeSampling()
        _ = try await tools.execute(write("two", "child/new.txt"))
        XCTAssertEqual(count, 1)
        await tools.afterCompaction()
        let after = try await tools.execute(write("three", "child/new.txt"))
        XCTAssertTrue(after.contains("Nested rule")); XCTAssertEqual(count, 1)
    }
    func testDuplicateToolIDsFailBeforeAnySideEffect() async throws {
        let (root, files) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        harness.onEvent = { if case .approval(let request?) = $0 { XCTFail("No approval should be requested"); request.resolve(false) } }
        let model = RecoveryModel([ModelMessage(role: "assistant", toolCalls: [write("same", "one.txt"), write("same", "two.txt")])])
        do { _ = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model); XCTFail("Expected invalid response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("duplicate")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
    }
}
