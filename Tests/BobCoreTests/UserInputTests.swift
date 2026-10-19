import XCTest
@testable import Bob
@testable import BobCore

private let questionJSON = #"{"questions":[{"id":"scope","header":"Scope","question":"Which scope?","options":[{"label":"Small (Recommended)","description":"Keep it focused."},{"label":"Large","description":"Include everything."}]}]}"#

private actor QuestionModel: ModelTransport {
    private var asked = false
    private(set) var receivedAnswer = false
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        guard tools.contains(where: { $0.name == "request_user_input" }) else { throw BobError.message("Missing question tool") }
        if !asked {
            asked = true
            return .init(role: "assistant", toolCalls: [.init(id: "question", name: "request_user_input", arguments: questionJSON)])
        }
        if let result = messages.last(where: { $0.toolCallID == "question" }),
           let response = try? JSONDecoder().decode(UserInputResponse.self, from: Data(result.text.utf8)) {
            receivedAnswer = response.answers["scope"]?.answers == ["Custom scope"]
        }
        return .init(role: "assistant", text: "Continuing with your answer.")
    }
}

@MainActor final class UserInputTests: XCTestCase {
    private func questions() throws -> UserInputQuestions {
        try JSONDecoder().decode(UserInputQuestions.self, from: Data(questionJSON.utf8))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for questions")
    }

    func testCodexResponseShapeAndCustomAnswer() throws {
        let questions = try questions()
        try questions.validate()
        let response = try questions.response(["scope": "Something else"])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary
        XCTAssertEqual(object, ["answers": ["scope": ["answers": ["Something else"]]]] as NSDictionary)
        XCTAssertTrue(questions.transcript(response).contains("Something else"))
        XCTAssertThrowsError(try questions.response([:]))
        XCTAssertThrowsError(try questions.response(["scope": " \n"]))
        XCTAssertThrowsError(try questions.response(["scope": "Small", "unknown": "extra"]))
    }

    func testRejectsMalformedQuestions() throws {
        for json in [#"{"questions":[]}"#,
                     questionJSON.replacingOccurrences(of: "\"id\":\"scope\"", with: "\"id\":\"\""),
                     questionJSON.replacingOccurrences(of: "Large", with: "Small (Recommended)")] {
            let request = try JSONDecoder().decode(UserInputQuestions.self, from: Data(json.utf8))
            XCTAssertThrowsError(try request.validate())
        }
    }

    func testCoordinatorDoesNotDefaultAndIgnoresStaleAndDoubleAnswers() async throws {
        var visible: UserInputRequest?
        var answers: [String] = []
        let coordinator = UserInputCoordinator(runID: UUID(), emit: { visible = $0 }, answered: { answers.append($0) })
        let request = try questions()
        let task = Task { try await coordinator.request(callID: "first", questions: request) }
        try await waitUntil { visible != nil }
        let stale = try XCTUnwrap(visible)
        stale.resolve([:])
        XCTAssertNotNil(visible)
        coordinator.cancel()
        let cancelled = try await task.value
        XCTAssertNil(cancelled)
        let second = Task { try await coordinator.request(callID: "second", questions: request) }
        try await waitUntil { visible != nil }
        stale.resolve(["scope": "Large"])
        XCTAssertEqual(visible?.callID, "second")
        let current = try XCTUnwrap(visible)
        current.resolve(["scope": "Custom"])
        current.resolve(["scope": "Large"])
        let response = try await second.value
        XCTAssertEqual(response?.answers["scope"]?.answers, ["Custom"])
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(visible)
    }

    func testTaskCancellationClearsPendingRequest() async throws {
        var visible: UserInputRequest?
        let coordinator = UserInputCoordinator(runID: UUID(), emit: { visible = $0 })
        let request = try questions()
        let task = Task { try await coordinator.request(callID: "cancel", questions: request) }
        try await waitUntil { visible != nil }
        task.cancel()
        let result = try await task.value
        XCTAssertNil(result)
        XCTAssertNil(visible)
    }

    func testHarnessPausesReturnsAnswerAndRetainsTrustedInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-questions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        var visible: UserInputRequest?
        var transcript = ""
        harness.onEvent = { event in
            if case .userInput(let request) = event { visible = request }
            if case .userAnswer(let text) = event { transcript = text }
        }
        let input = AgentInput(), model = QuestionModel()
        let task = Task {
            try await harness.run(configuration: .init(provider: .compatible, model: "fixture", baseURL: "http://localhost", token: ""),
                messages: [.init(role: "user", text: "Ask me about scope")],
                files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")),
                project: root.path, transport: model, input: input)
        }
        try await waitUntil { visible != nil }
        let beforeAnswer = await model.receivedAnswer
        XCTAssertFalse(beforeAnswer)
        visible?.resolve(["scope": "Custom scope"])
        let history = try await task.value
        let received = await model.receivedAnswer
        XCTAssertTrue(received)
        XCTAssertTrue(history.contains { $0.role == "tool" && $0.toolCallID == "question" })
        XCTAssertEqual(input.userMessages, [transcript])
        XCTAssertFalse(input.hasPending)
        XCTAssertNil(visible)
    }

    func testRecoveryRestoresUserAnswersWithoutReplayingTools() throws {
        let request = try questions()
        let response = try request.response(["scope": "Custom scope"])
        let history: [ModelMessage] = [
            .init(role: "user", text: "Ask me"),
            .init(role: "assistant", toolCalls: [.init(id: "q", name: "request_user_input", arguments: questionJSON)]),
            .init(role: "tool", text: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), toolCallID: "q")
        ]
        let recovered = ChatTranscript.recoveredMessages(history: history, runID: UUID())
        XCTAssertEqual(recovered.filter { $0.role == .user }.map(\.text), [request.transcript(response)])
    }

    func testQuestionsArePerChatAndStopAndSteeringDismissThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-question-chats-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { store.shutdown() }
        func start() -> UUID {
            store.newSession(provider: .compatible)
            store.setModel("fixture")
            store.draft = "Ask me about scope"
            store.send(transport: QuestionModel(), reviewer: FixtureToolSafetyReviewer())
            return store.selectedID!
        }
        let first = start()
        try await waitUntil { store.userInput != nil }
        let firstRequest = try XCTUnwrap(store.userInput)
        firstRequest.draft.other.insert("scope")
        firstRequest.draft.custom["scope"] = "Unfinished answer"
        let second = start()
        try await waitUntil { store.userInput != nil }
        let secondRequest = try XCTUnwrap(store.userInput)
        XCTAssertNotEqual(firstRequest.runID, secondRequest.runID)
        store.select(first)
        XCTAssertEqual(store.userInput?.id, firstRequest.id)
        XCTAssertEqual(store.userInput?.draft.custom["scope"], "Unfinished answer")
        XCTAssertTrue(store.userInput?.draft.other.contains("scope") == true)
        store.draft = "Keep this composer draft"
        firstRequest.resolve(["scope": "Custom scope"])
        try await waitUntil { !store.runningSessionIDs.contains(first) }
        XCTAssertEqual(store.draft, "Keep this composer draft")
        XCTAssertTrue(store.selected!.messages.contains { $0.role == .user && $0.text.contains("Custom scope") })
        store.select(second)
        XCTAssertEqual(store.userInput?.id, secondRequest.id)
        store.stop()
        try await waitUntil { !store.runningSessionIDs.contains(second) }
        XCTAssertNil(store.userInput)
        let third = start()
        try await waitUntil { store.userInput != nil }
        store.draft = "Actually, choose for me"
        store.send()
        try await waitUntil { !store.runningSessionIDs.contains(third) }
        XCTAssertNil(store.userInput)
        XCTAssertTrue(store.selected!.turns.contains { $0.role == "user" && $0.text == "Actually, choose for me" })
    }

    func testMultipleQuestionsRequireAllAnswersAndRetainMapping() throws {
        let item = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(questionJSON.utf8)) as? [String: Any])?["questions"] as? [[String: Any]])[0]
        var second = item
        second["id"] = "timing"
        let data = try JSONSerialization.data(withJSONObject: ["questions": [item, second]])
        let request = try JSONDecoder().decode(UserInputQuestions.self, from: data)
        try request.validate()
        XCTAssertThrowsError(try request.response(["scope": "Large"]))
        let response = try request.response(["scope": "Large", "timing": "Tomorrow"])
        XCTAssertEqual(response.answers["scope"]?.answers, ["Large"])
        XCTAssertEqual(response.answers["timing"]?.answers, ["Tomorrow"])
    }

}
