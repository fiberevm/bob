import XCTest
@testable import Bob
@testable import BobCore

private actor QuietTranscriptModel: ModelTransport {
    private var responses: [ModelMessage]
    init(_ responses: [ModelMessage]) { self.responses = responses }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        guard !responses.isEmpty else { throw BobError.message("Unexpected model call") }
        return responses.removeFirst()
    }
}

@MainActor final class ChatTranscriptTests: XCTestCase {
    func testChatKeepsTextAndToolResultsInOrderAndPersistsThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-transcript-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Project contents".utf8).write(to: root.appendingPathComponent("README.md"))
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage)
        store.newSession(provider: .compatible)
        store.setModel("fixture")
        XCTAssertNil(store.sessionStatus(try XCTUnwrap(store.selected)))
        let call = ToolCall(id: "read1", name: "read_file", arguments: #"{"path":"README.md"}"#)
        let model = QuietTranscriptModel([ModelMessage(role: "assistant", text: "I'll inspect the project.", toolCalls: [call]), ModelMessage(role: "assistant", text: "The project is ready.")])
        store.draft = "Inspect the project"
        store.send(transport: model, reviewer: FixtureToolSafetyReviewer())
        XCTAssertEqual(store.sessionStatus(try XCTUnwrap(store.selected)), .working)
        let runningID = try XCTUnwrap(store.selectedID)
        store.newSession()
        XCTAssertNil(store.sessionStatus(try XCTUnwrap(store.selected)))
        XCTAssertEqual(store.sessionStatus(try XCTUnwrap(store.sessions.first { $0.id == runningID })), .working)
        store.select(runningID)
        for _ in 0..<200 {
            if !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.sessionStatus(try XCTUnwrap(store.selected)), .done)
        let messages = try XCTUnwrap(store.selected?.messages)
        XCTAssertEqual(messages.map(\.text), ["Inspect the project", "I'll inspect the project.", "", "The project is ready."])
        XCTAssertEqual(messages[2].tool?.status, .completed)
        XCTAssertEqual(messages[2].tool?.output, "Project contents")
        XCTAssertEqual(messages[2].tool?.call, call)
        store.shutdown()
        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(reopened.selected?.messages, messages)
        XCTAssertEqual(reopened.sessionStatus(try XCTUnwrap(reopened.selected)), .done)
        reopened.shutdown()
    }

    func testAnEmptyModelReplyShowsAnErrorAndStopsThinking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-empty-reply-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        store.newSession(provider: .compatible); store.setModel("fixture")
        store.draft = "Hello"
        store.send(transport: QuietTranscriptModel([ModelMessage(role: "assistant")]))
        for _ in 0..<200 {
            if !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.selected?.messages.last?.role, .error)
        XCTAssertTrue(store.selected?.messages.last?.text.contains("without a reply") == true)
        XCTAssertTrue(store.runningSessionIDs.isEmpty)
        XCTAssertNil(store.sessionStatus(try XCTUnwrap(store.selected)))
        store.shutdown()
    }

    func testRecoveryKeepsToolCallsBetweenAssistantMessages() {
        let call = ToolCall(id: "read", name: "read_file", arguments: #"{"path":"README.md"}"#)
        let runID = UUID()
        let messages = ChatTranscript.recoveredMessages(history: [ModelMessage(role: "user", text: "Inspect"), ModelMessage(role: "assistant", text: "Reading", toolCalls: [call]), ModelMessage(role: "tool", text: "Contents", toolCallID: call.id), ModelMessage(role: "assistant", text: "Done")], runID: runID)
        XCTAssertEqual(messages.map(\.text), ["Reading", "", "Done"])
        XCTAssertEqual(messages.first?.id, runID)
        XCTAssertEqual(messages[1].tool?.output, "Contents")
        XCTAssertEqual(messages[1].tool?.status, .completed)
    }

    func testAnOlderJournalCannotEraseANewerUnstartedTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-old-journal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state"), store = AppStore(projectPath: root.path, storageDirectory: storage)
        let session = try XCTUnwrap(store.selectedID), old = Message(role: .assistant, text: "Old reply")
        let messages = [Message(role: .user, text: "Old prompt"), old, Message(role: .user, text: "New prompt"), Message(role: .assistant, text: "")]
        let turns = [ModelMessage(role: "user", text: "Old prompt"), ModelMessage(role: "assistant", text: "Old reply"), ModelMessage(role: "user", text: "New prompt")]
        store.mutate(session) { $0.messages = messages; $0.turns = turns }
        store.shutdown()
        let journal = TurnJournal(url: storage.appendingPathComponent("turns").appendingPathComponent(session.uuidString + ".jsonl"))
        try await journal.begin(runID: old.id, history: Array(turns.prefix(2)))
        try await journal.finish()
        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(reopened.selected?.messages, messages)
        XCTAssertEqual(reopened.selected?.turns, turns)
        reopened.shutdown()
    }

    func testToolFailuresDeclinesAndCancellationHaveDistinctStates() {
        let call = ToolCall(id: "command", name: "run_command", arguments: #"{"command":"swift test"}"#)
        for (output, cancelled, expected) in [("Exit: 1\nTests failed", false, ToolActivity.Status.failed), ("The user declined this command.", false, .declined), ("Inspect current state", true, .cancelled), ("Exit: 0\nTests passed", false, .completed)] {
            var activity = ToolActivity(call: call)
            activity.finish(output: output, cancelled: cancelled)
            XCTAssertEqual(activity.status, expected)
        }
    }
}
