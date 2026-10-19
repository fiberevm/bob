import XCTest
@testable import Bob
@testable import BobCore

private actor HeldConversationModel: ModelTransport {
    let prefix: String
    private var released = false
    init(_ prefix: String) { self.prefix = prefix }
    func release() { released = true }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        await onText(prefix)
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        await onText("finished")
        return .init(role: "assistant", text: prefix + "finished")
    }
}

private struct FailedConversationModel: ModelTransport {
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        throw BobError.message("Fixture failure")
    }
}

private actor ApprovalConversationModel: ModelTransport {
    let path: String
    private var requested = false
    init(_ path: String) { self.path = path }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        if requested { return .init(role: "assistant", text: "Finished " + path) }
        requested = true
        return .init(role: "assistant", toolCalls: [.init(id: "same-call-id", name: "write_file", arguments: "{\"path\":\"\(path)\",\"content\":\"saved\"}")])
    }
}

@MainActor private final class SurfaceBrowserFixture: AgentBrowser {
    var currentURL = "https://example.com"
    var cancellations = 0
    func navigate(_ address: String) async throws -> String { "" }
    func readPage() async throws -> String { "" }
    func targetDescription(snapshot: String, reference: Int, typing: Bool) async throws -> String { "" }
    func click(snapshot: String, reference: Int) async throws -> String { "" }
    func type(snapshot: String, reference: Int, text: String) async throws -> String { "" }
    func scrollPage(direction: String) async throws -> String { "" }
    func cancelAgentOperation() { cancellations += 1 }
}

@MainActor final class ConversationConcurrencyTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-concurrent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for chat state", file: file, line: line)
    }
    private func start(_ store: AppStore, prompt: String, model: any ModelTransport) -> UUID {
        store.newSession(provider: .compatible)
        store.setModel("fixture")
        store.draft = prompt
        store.send(transport: model, reviewer: FixtureToolSafetyReviewer())
        return store.selectedID!
    }

    func testSelectingConversationRequestsComposerFocusIncludingReselection() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { store.shutdown() }
        let first = try XCTUnwrap(store.selectedID)
        let second = Session(projectPath: root.path)
        store.sessions.append(second)
        let initialRequest = store.composerFocusRequest

        store.select(second.id)
        let selectionRequest = try XCTUnwrap(store.composerFocusRequest)
        XCTAssertEqual(store.selectedID, second.id)
        XCTAssertNotEqual(selectionRequest, initialRequest)

        store.select(second.id)
        let reselectionRequest = try XCTUnwrap(store.composerFocusRequest)
        XCTAssertNotEqual(reselectionRequest, selectionRequest)

        store.select(first)
        XCTAssertEqual(store.selectedID, first)
        XCTAssertNotEqual(store.composerFocusRequest, reselectionRequest)
    }

    func testCompletionAlertsArePerSuccessfulRunIncludingBackgroundChats() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        var alerts: [(UUID, UUID)] = []
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"),
                             completionAlert: { alerts.append(($0.id, $1)) })
        defer { store.shutdown() }
        let alpha = HeldConversationModel("Alpha "), beta = HeldConversationModel("Beta ")
        let first = start(store, prompt: "First", model: alpha)
        let second = start(store, prompt: "Second", model: beta)
        await alpha.release()
        try await waitUntil { !store.runningSessionIDs.contains(first) }
        XCTAssertEqual(store.selectedID, second)
        XCTAssertEqual(alerts.map { $0.0 }, [first])
        await beta.release()
        try await waitUntil { store.runningSessionIDs.isEmpty }
        XCTAssertEqual(alerts.map { $0.0 }, [first, second])
        XCTAssertEqual(Set(alerts.map { $0.1 }).count, 2)

        _ = start(store, prompt: "Stop", model: HeldConversationModel("Waiting "))
        store.stop()
        try await waitUntil { store.runningSessionIDs.isEmpty }
        _ = start(store, prompt: "Fail", model: FailedConversationModel())
        try await waitUntil { store.runningSessionIDs.isEmpty }
        XCTAssertTrue(store.selected?.messages.contains { $0.role == .error } == true)
        _ = start(store, prompt: "Shutdown", model: HeldConversationModel("Waiting "))
        store.shutdown()
        try await waitUntil { store.runningSessionIDs.isEmpty }
        XCTAssertEqual(alerts.count, 2, "Stopped, failed, and shutdown runs must not alert")
    }

    func testTwoChatsStreamIndependentlyAndFinishingOneLeavesOtherRunning() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state"), store = AppStore(projectPath: root.path, storageDirectory: storage)
        let alpha = HeldConversationModel("Alpha "), beta = HeldConversationModel("Beta ")
        let first = start(store, prompt: "First prompt", model: alpha)
        store.newSession()
        XCTAssertFalse(store.isRunning)
        store.selectModel(.init(id: "other-model"), provider: .compatible)
        XCTAssertEqual(store.selectedModelID, "other-model", "Background runs must not disable this chat's model selector")
        let second = start(store, prompt: "Second prompt", model: beta)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.runningSessionIDs, [first, second])
        try await waitUntil {
            store.sessions.first { $0.id == first }?.messages.last?.text == "Alpha " &&
            store.sessions.first { $0.id == second }?.messages.last?.text == "Beta "
        }
        await beta.release()
        try await waitUntil { !store.runningSessionIDs.contains(second) }
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.runningSessionIDs, [first])
        XCTAssertEqual(store.selected?.messages.last?.text, "Beta finished")
        store.select(first)
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.sessionStatus(try XCTUnwrap(store.selected)), .working)
        await alpha.release()
        try await waitUntil { store.runningSessionIDs.isEmpty }
        XCTAssertEqual(store.selected?.messages.last?.text, "Alpha finished")
        XCTAssertTrue(store.sessions.allSatisfy { store.sessionStatus($0) == .done })
        let saved = store.sessions
        store.shutdown()
        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(reopened.sessions.map(\.messages), saved.map(\.messages))
        XCTAssertEqual(reopened.sessions.map(\.turns), saved.map(\.turns))
        reopened.shutdown()
    }

    func testApprovalsStayWithTheirChatWhenAnotherChatFinishes() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        let first = start(store, prompt: "Write first file", model: ApprovalConversationModel("first.txt"))
        try await waitUntil { store.approval != nil }
        let firstApproval = try XCTUnwrap(store.approval)
        let second = start(store, prompt: "Write second file", model: ApprovalConversationModel("second.txt"))
        try await waitUntil { store.approval != nil }
        let secondApproval = try XCTUnwrap(store.approval)
        XCTAssertNotEqual(firstApproval.runID, secondApproval.runID)
        XCTAssertNotEqual(firstApproval.id, secondApproval.id)
        firstApproval.resolve(true)
        try await waitUntil { !store.runningSessionIDs.contains(first) }
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.approval?.id, secondApproval.id)
        firstApproval.resolve(true)
        XCTAssertEqual(store.approval?.id, secondApproval.id)
        secondApproval.resolve(false)
        try await waitUntil { !store.runningSessionIDs.contains(second) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("first.txt")), "saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path))
        store.shutdown()
    }

    func testStoppingSelectedChatLeavesBackgroundApprovalAndShutdownStopsAll() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        let first = start(store, prompt: "Write first", model: ApprovalConversationModel("first.txt"))
        try await waitUntil { store.approval != nil }
        let firstApproval = try XCTUnwrap(store.approval)
        let second = start(store, prompt: "Write second", model: ApprovalConversationModel("second.txt"))
        try await waitUntil { store.approval != nil }
        store.stop()
        try await waitUntil { !store.runningSessionIDs.contains(second) }
        store.select(first)
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.approval?.id, firstApproval.id)
        let third = start(store, prompt: "Background work", model: HeldConversationModel("Third "))
        XCTAssertEqual(store.runningSessionIDs, [first, third])
        store.shutdown()
        try await waitUntil { store.runningSessionIDs.isEmpty }
        XCTAssertTrue(store.sessions.allSatisfy { $0.messages.last?.text.contains("Stopped") == true })
        firstApproval.resolve(true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path))
    }

    func testSharedSurfaceOwnershipAndCancellationAreBoundToRun() async throws {
        let coordinator = AgentSurfaceCoordinator(), browser = SurfaceBrowserFixture(), tabID = UUID()
        let owner = AgentSurfaceAccess(runID: UUID(), coordinator: coordinator)
        let other = AgentSurfaceAccess(runID: UUID(), coordinator: coordinator, tabKind: { _ in .browser })
        let call = ToolCall(id: "browser", name: "browser_read", arguments: "{}")
        try owner.claim(for: call)
        XCTAssertThrowsError(try other.claim(for: call))
        XCTAssertThrowsError(try other.claim(for: .init(id: "open", name: "workspace_open_tab", arguments: #"{"kind":"browser","url":"https://example.com"}"#)))
        XCTAssertThrowsError(try other.claim(for: .init(id: "close", name: "workspace_close_tab", arguments: "{\"tab_id\":\"\(tabID)\"}")))
        other.cancel(browser: browser, computer: nil)
        other.release()
        XCTAssertTrue(owner.owns(.browser))
        XCTAssertEqual(browser.cancellations, 0)
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let model = HeldConversationModel("Other ")
        await model.release()
        _ = try await AgentHarness(reviewer: FixtureToolSafetyReviewer()).run(
            configuration: .init(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: ""), messages: [],
            files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")), project: root.path,
            transport: model, browser: browser, surfaces: other)
        XCTAssertEqual(browser.cancellations, 0, "Finishing an unrelated run must not cancel the owner's navigation")
        owner.cancel(browser: browser, computer: nil)
        XCTAssertEqual(browser.cancellations, 1)
        owner.release()
        try other.claim(for: call)
        XCTAssertTrue(other.owns(.browser))
        other.release()
    }
}
