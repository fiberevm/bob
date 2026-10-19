import XCTest
@testable import Bob
@testable import BobCore

@MainActor final class PromptDraftTests: XCTestCase {
    func testDraftsFollowConversationsAndSurviveReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-drafts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage)
        let first = try XCTUnwrap(store.selectedID)
        store.mutate(first) { $0.messages.append(Message(role: .user, text: "Earlier prompt")) }
        let text = "  Unfinished prompt\nwith another line  "
        store.draft = text
        store.newSession()
        let second = try XCTUnwrap(store.selectedID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.draft, "")
        store.draft = "Second draft"
        store.select(first)
        XCTAssertEqual(store.draft, text)
        store.select(first)
        XCTAssertEqual(store.draft, text)
        store.shutdown()

        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(reopened.draft, text)
        reopened.select(second)
        XCTAssertEqual(reopened.draft, "Second draft")
        reopened.draft = ""
        reopened.select(first)
        XCTAssertEqual(reopened.draft, text)
        reopened.deleteSession(first)
        XCTAssertEqual(reopened.selectedID, second)
        XCTAssertEqual(reopened.draft, "")
        reopened.shutdown()

        let final = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(final.draft, "")
        final.shutdown()
    }

    func testTypingAutosavesWithoutSwitchingOrShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-draft-autosave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage)
        store.draft = "Automatically saved"
        try await Task.sleep(for: .milliseconds(600))
        let reopened = AppStore(projectPath: root.path, storageDirectory: storage)
        XCTAssertEqual(reopened.draft, "Automatically saved")
        reopened.shutdown()
        store.shutdown()
    }

    func testLegacySessionWithoutDraftDecodes() throws {
        let session = Session(projectPath: "/tmp/project")
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertNil(restored.promptDraft)
    }
}
