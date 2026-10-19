import XCTest
import AppKit
import Combine
@testable import Bob
@testable import BobCore

private actor ActivityMenuModel: ModelTransport {
    let requestsApproval: Bool
    private var requested = false
    init(requestsApproval: Bool = false) { self.requestsApproval = requestsApproval }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        if requestsApproval && !requested {
            requested = true
            return .init(role: "assistant", toolCalls: [.init(id: "approval", name: "write_file", arguments: #"{"path":"example.txt","content":"example"}"#)])
        }
        while true { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor final class ActivityMenuTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for activity")
    }

    private func start(_ store: AppStore, approval: Bool = false) -> UUID {
        store.newSession(provider: .compatible)
        store.setModel("fixture")
        store.draft = approval ? "Write file" : "Wait"
        store.send(transport: ActivityMenuModel(requestsApproval: approval), reviewer: FixtureToolSafetyReviewer())
        return store.selectedID!
    }

    func testAggregatesBackgroundChatsAndProjectsAndUnregisters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-activity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("first"), completionAlert: { _, _ in })
        let second = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("second"), completionAlert: { _, _ in })
        defer { first.shutdown(); second.shutdown() }
        let menu = ActivityMenuStore()
        XCTAssertEqual(menu.summary, "Bob: Ready")
        XCTAssertEqual(menu.symbol, "circle")
        menu.register(first, window: nil)
        menu.register(second, window: nil)
        menu.register(first, window: nil) // Repeated view updates must not duplicate entries.
        var updates = 0
        let observation = menu.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        let background = start(first)
        _ = start(first)
        _ = start(second)
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.symbol, "circle.dotted.circle.fill")
        XCTAssertEqual(menu.summary, "Bob: 3 active chats")
        let item = try XCTUnwrap(menu.items.first { $0.chat.id == background })
        _ = NSApplication.shared
        menu.show(item)
        XCTAssertEqual(first.selectedID, background)
        XCTAssertGreaterThan(updates, 0)
        menu.unregister(second)
        XCTAssertEqual(menu.items.count, 2)
        first.shutdown()
        try await waitUntil { menu.items.isEmpty }
        XCTAssertEqual(menu.summary, "Bob: Ready")
    }

    func testBackgroundApprovalTakesPriorityAndClearsOnStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-activity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"), completionAlert: { _, _ in })
        defer { store.shutdown() }
        let menu = ActivityMenuStore()
        menu.register(store, window: nil)
        let approvalChat = start(store, approval: true)
        try await waitUntil { store.approval != nil }
        _ = start(store)
        XCTAssertNil(store.approval, "The selected chat is not the chat awaiting approval")
        XCTAssertEqual(menu.approvalCount, 1)
        XCTAssertEqual(menu.items.first?.chat.id, approvalChat)
        XCTAssertEqual(menu.symbol, "exclamationmark.circle.fill")
        XCTAssertEqual(menu.summary, "Bob: 1 awaiting approval · 2 active")
        store.select(approvalChat)
        store.stop()
        try await waitUntil { menu.approvalCount == 0 && menu.items.count == 1 }
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.symbol, "circle.dotted.circle.fill")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("example.txt").path))
    }
}
