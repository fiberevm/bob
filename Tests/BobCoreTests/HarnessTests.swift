import XCTest
@testable import Bob
@testable import BobCore

private actor ScriptedModel: ModelTransport {
    private var responses: [ModelMessage]
    private(set) var histories: [[ModelMessage]] = []
    init(_ responses: [ModelMessage]) { self.responses = responses }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        histories.append(messages)
        guard !responses.isEmpty else { throw BobError.message("Unexpected extra model call") }
        let response = responses.removeFirst()
        if !response.text.isEmpty { await onText(response.text) }
        return response
    }
}

@MainActor final class HarnessTests: XCTestCase {
    private func temporaryWorkspace() throws -> (URL, WorkspaceFiles) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-harness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent(".checkpoints")))
    }
    private let config = ModelConfiguration(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: "")

    func testConversationRenameAndDeletePersist() throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage)
        let first = try XCTUnwrap(store.selectedID)
        store.renameSession(first, to: "  My conversation  ")
        XCTAssertEqual(store.selected?.title, "My conversation")
        store.renameSession(first, to: " \n ")
        XCTAssertEqual(store.selected?.title, "My conversation")
        store.mutate(first) { $0.messages.append(Message(role: .user, text: "Hello")) }
        store.newSession()
        let second = try XCTUnwrap(store.selectedID)
        store.draft = "Keep this draft"
        store.deleteSession(first)
        XCTAssertEqual(store.selectedID, second)
        XCTAssertEqual(store.draft, "Keep this draft")
        store.renameSession(second, to: "Saved name")
        store.shutdown()
        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(reopened.sessions.count, 1)
        XCTAssertEqual(reopened.selected?.title, "Saved name")
        reopened.deleteSession(second)
        XCTAssertEqual(reopened.sessions.count, 1)
        XCTAssertNotEqual(reopened.selectedID, second)
        XCTAssertEqual(reopened.selected?.title, "New Chat")
        reopened.shutdown()
    }

    func testProjectWindowsHaveSeparateSessionsAndPersistentState() throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("state")
        let one = AppStore(projectPath: first.path, storageDirectory: storage)
        let two = AppStore(projectPath: second.path, storageDirectory: storage)
        one.mutate(one.selectedID!) { $0.messages.append(Message(role: .user, text: "Existing conversation")) }
        one.newSession()
        XCTAssertEqual(one.sessions.count, 2)
        XCTAssertEqual(two.sessions.count, 1)
        XCTAssertTrue(one.sessions.allSatisfy { $0.projectPath == first.path })
        XCTAssertEqual(two.selected?.projectPath, second.path)
        one.shutdown(); two.shutdown()
        let reopened = AppStore(projectPath: first.path, storageDirectory: storage)
        XCTAssertEqual(reopened.sessions.count, 2)
        reopened.shutdown()
    }

    func testNewSessionReusesSelectedEmptyChatAndPreservesItsDraft() throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage)
        let originalID = try XCTUnwrap(store.selectedID)
        store.draft = "A prompt in progress"
        store.setModel("chosen-model")
        store.openPanel(.editor)
        store.newSession()
        store.newSession()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedID, originalID)
        XCTAssertEqual(store.draft, "A prompt in progress")
        XCTAssertEqual(store.selected?.model, "chosen-model")
        XCTAssertTrue(store.showWorkspacePanel)
        XCTAssertEqual(store.selectedPanel, .editor)

        store.mutate(originalID) { $0.messages.append(Message(role: .user, text: "Sent prompt")) }
        store.newSession()
        let newID = try XCTUnwrap(store.selectedID)
        XCTAssertNotEqual(newID, originalID)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.draft.isEmpty)
        store.newSession(provider: .claude)
        XCTAssertEqual(store.selectedID, newID)
        XCTAssertEqual(store.selected?.provider, .claude)
        XCTAssertEqual(store.sessions.count, 2)
        store.shutdown()

        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(reopened.sessions.count, 2)
        XCTAssertEqual(reopened.selectedID, newID)
        reopened.shutdown()
    }

    func testNewChatRevealOnlyTriggersForCreation() throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage)
        let originalID = try XCTUnwrap(store.selectedID)
        XCTAssertNil(store.lastCreatedSessionID)

        store.newSession()
        XCTAssertNil(store.lastCreatedSessionID, "Reusing an empty chat must not replay the reveal")
        store.mutate(originalID) { $0.messages.append(Message(role: .user, text: "Existing chat")) }
        store.newSession()
        let createdID = try XCTUnwrap(store.selectedID)
        XCTAssertNotEqual(createdID, originalID)
        XCTAssertEqual(store.lastCreatedSessionID, createdID)

        store.newSession()
        XCTAssertEqual(store.lastCreatedSessionID, createdID)
        store.select(originalID)
        XCTAssertEqual(store.lastCreatedSessionID, createdID, "Selecting an existing chat must not trigger a reveal")
        store.newSession()
        XCTAssertNotEqual(store.lastCreatedSessionID, createdID)
        XCTAssertEqual(store.lastCreatedSessionID, store.selectedID)
        store.shutdown()

        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertNil(reopened.lastCreatedSessionID, "Restoring a window must not trigger a reveal")
        reopened.shutdown()
    }

    func testWorkspacePanelAndEditorSurviveChatChanges() throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        XCTAssertTrue(store.showWorkspacePanel)
        let first = try XCTUnwrap(store.selectedID)
        store.openPanel(.editor)
        store.editorPath = root.appendingPathComponent("draft.swift").path
        store.editorOriginal = "original"
        store.editorText = "unsaved edit"
        store.mutate(first) { $0.messages.append(Message(role: .user, text: "Existing conversation")) }
        store.newSession()
        XCTAssertNotEqual(store.selectedID, first)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.showWorkspacePanel)
        XCTAssertEqual(store.selectedPanel, .editor)
        XCTAssertEqual(store.editorText, "unsaved edit")
        XCTAssertTrue(store.editorDirty)
        XCTAssertNil(store.error)

        store.draft = "Prompt in progress"
        store.openPanel(.changes)
        XCTAssertEqual(store.draft, "Prompt in progress")
        XCTAssertEqual(store.editorText, "unsaved edit")
        store.select(first)
        XCTAssertEqual(store.selectedID, first)
        XCTAssertEqual(store.selectedPanel, .changes)
        XCTAssertEqual(store.editorText, "unsaved edit")
        store.openPanel(.editor)
        XCTAssertTrue(store.showWorkspacePanel)
        XCTAssertEqual(store.editorText, "unsaved edit")
        store.shutdown()
    }

    func testNativeToolLoopReadsFileAndFeedsResultBackToModel() async throws {
        let (root, files) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("project content".utf8).write(to: root.appendingPathComponent("README.md"))
        let model = ScriptedModel([
            ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "read1", name: "read_file", arguments: #"{"path":"README.md"}"#)]),
            ModelMessage(role: "assistant", text: "Read the project.")
        ])
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        let result = try await harness.run(configuration: config, messages: [ModelMessage(role: "user", text: "Inspect")], files: files, project: root.path, transport: model)
        XCTAssertEqual(result[2].role, "tool")
        XCTAssertEqual(result[2].toolCallID, "read1")
        XCTAssertEqual(result[2].text, "project content")
        let histories = await model.histories
        XCTAssertEqual(histories.count, 2)
        XCTAssertEqual(histories[1].last?.text, "project content")
    }

    func testNativeToolLoopContinuesPastSixteenStepsUntilModelFinishes() async throws {
        let (root, files) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "project content".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let calls = (0..<32).map { ToolCall(id: "read-\($0)", name: "read_file", arguments: #"{"path":"README.md"}"#) }
        let model = ScriptedModel(calls.map { ModelMessage(role: "assistant", toolCalls: [$0]) } + [.init(role: "assistant", text: "Finished the whole task.")])
        let journalURL = root.appendingPathComponent("turn.jsonl")
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        let history = try await harness.run(configuration: config, messages: [.init(role: "user", text: "Inspect the project")],
            files: files, project: root.path, transport: model, journal: TurnJournal(url: journalURL))
        XCTAssertEqual(history.last?.text, "Finished the whole task.")
        XCTAssertEqual(history.filter { $0.role == "tool" }.map(\.toolCallID), calls.map { Optional($0.id) })
        XCTAssertTrue(history.filter { $0.role == "tool" }.allSatisfy { $0.text == "project content" })
        let histories = await model.histories
        XCTAssertEqual(histories.count, 33)
        let recovered = try XCTUnwrap(TurnJournal.recover(from: journalURL))
        XCTAssertEqual(recovered.history, history)
        XCTAssertEqual(recovered.reviews.count, 32)
        XCTAssertFalse(recovered.interrupted)
    }

    func testDeclinedWriteDoesNotTouchTheFile() async throws {
        let (root, files) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScriptedModel([
            ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "write1", name: "write_file", arguments: #"{"path":"new.txt","content":"proposed"}"#)]),
            ModelMessage(role: "assistant", text: "Write declined.")
        ])
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        harness.onEvent = { if case .approval(let request) = $0 { request?.resolve(false) } }
        let result = try await harness.run(configuration: config, messages: [ModelMessage(role: "user", text: "Write")], files: files, project: root.path, transport: model)
        XCTAssertTrue(result[2].text.contains("declined"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }

    func testApprovedWriteCreatesUndoCheckpoint() async throws {
        let (root, files) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScriptedModel([
            ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "write1", name: "write_file", arguments: #"{"path":"new.txt","content":"approved"}"#)]),
            ModelMessage(role: "assistant", text: "Saved.")
        ])
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer()); harness.onEvent = { if case .approval(let request) = $0 { request?.resolve(true) } }
        _ = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model)
        let text = try await files.read("new.txt")
        XCTAssertEqual(text, "approved")
        _ = try await files.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }
}
