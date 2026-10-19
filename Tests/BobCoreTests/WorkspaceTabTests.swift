import XCTest
@testable import Bob
@testable import BobCore

private actor WorkspaceTabModel: ModelTransport {
    private var step = 0
    private var fileID = ""
    private(set) var toolNames: Set<String> = []
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        toolNames = Set(tools.map(\.name))
        defer { step += 1 }
        let name: String, args: [String: String]
        switch step {
        case 0: name = "workspace_open_tab"; args = ["kind": "editor", "path": "one.swift"]
        case 1:
            let result = try XCTUnwrap(messages.last?.text.data(using: .utf8))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
            let tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
            fileID = try XCTUnwrap(tabs.first?["tab_id"] as? String)
            name = "workspace_open_tab"; args = ["kind": "changes"]
        case 2: name = "workspace_select_tab"; args = ["tab_id": fileID]
        case 3: name = "workspace_close_tab"; args = ["tab_id": fileID]
        case 4: name = "workspace_tabs"; args = [:]
        default: return ModelMessage(role: "assistant", text: "Showing changes.")
        }
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "tab-\(step)", name: name, arguments: arguments)])
    }
}

@MainActor final class WorkspaceTabTests: XCTestCase {
    private func fixture() throws -> (URL, AppStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-tabs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("let one = 1\n".utf8).write(to: root.appendingPathComponent("one.swift"))
        try Data("let two = 2\n".utf8).write(to: root.appendingPathComponent("two.swift"))
        return (root, AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state")))
    }

    func testEditorStartsOpenAndRemainsAfterClosingOtherPanels() throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor])
        XCTAssertEqual(store.selectedPanel, .editor)
        XCTAssertFalse(store.canCloseSelectedTab)
        XCTAssertTrue(store.showWorkspacePanel)
        XCTAssertFalse(store.browser.hasCreatedWebView)
        store.openPanel(.editor)
        let editor = try XCTUnwrap(store.selectedTabID)
        store.openPanel(.changes)
        let changes = try XCTUnwrap(store.selectedTabID)
        store.openPanel(.editor)
        XCTAssertEqual(store.selectedTabID, editor)
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor, .changes])
        XCTAssertEqual(store.selectedTabID, editor)
        try store.closeTab(editor)
        XCTAssertEqual(store.selectedTabID, editor)
        XCTAssertTrue(store.showWorkspacePanel)
        try store.closeTab(changes)
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor])
        XCTAssertEqual(store.selectedTabID, editor)
        XCTAssertTrue(store.showWorkspacePanel)
        let workspace = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(store.tabsDescription().utf8)) as? [String: Any])
        XCTAssertEqual(workspace["visible"] as? Bool, true)
        store.openPanel(.editor)
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor])
        XCTAssertTrue(store.showWorkspacePanel)
    }

    func testSeparateFileTabsPreserveUnsavedBuffersAndDeduplicateResolvedPaths() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.openPanel(.editor)
        let empty = store.selectedTabID
        let first = try await store.openFileTab("one.swift")
        XCTAssertEqual(first, empty)
        store.editorText = "unsaved one"
        let second = try await store.openFileTab("two.swift")
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(store.editorText, "let two = 2\n")
        store.editorText = "unsaved two"
        let reused = try await store.openFileTab(root.appendingPathComponent("./one.swift").path)
        XCTAssertEqual(reused, first)
        XCTAssertEqual(store.openTabs.count, 2)
        XCTAssertEqual(store.editorText, "unsaved one")
        XCTAssertEqual(store.editorOriginal, "let one = 1\n")
        XCTAssertTrue(store.hasUnsavedEdits)
        XCTAssertThrowsError(try store.closeWorkspaceTab(second))
        XCTAssertThrowsError(try store.closeTab(first))
        store.editorText = store.editorOriginal
        XCTAssertTrue(store.hasUnsavedEdits, "A dirty background tab must still block agent writes")
        store.selectTab(second)
        XCTAssertEqual(store.editorText, "unsaved two")
        store.editorText = store.editorOriginal
        try store.closeTab(second)
        XCTAssertEqual(store.selectedTabID, first)
        XCTAssertEqual(store.editorPath, root.appendingPathComponent("one.swift").path)
        XCTAssertEqual(store.editorText, "let one = 1\n")
        XCTAssertFalse(store.hasUnsavedEdits)
    }

    func testCleanAndDiscardedFilesReuseTheCurrentEditorTab() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = try await store.openFileTab("one.swift")
        let second = try await store.openFileTab("two.swift")
        XCTAssertEqual(second, first)
        XCTAssertEqual(store.openTabs.count, 1)
        XCTAssertEqual(store.selectedTabID, first)
        XCTAssertEqual(store.editorPath, root.appendingPathComponent("two.swift").path)
        XCTAssertEqual(store.editorText, "let two = 2\n")
        XCTAssertEqual(store.editorOriginal, "let two = 2\n")
        XCTAssertEqual(store.tabTitle(try XCTUnwrap(store.selectedTab)), "two.swift")
        XCTAssertFalse(store.hasUnsavedEdits)

        store.editorText = "discarded changes"
        store.editorText = store.editorOriginal
        let reopened = try await store.openFileTab("one.swift")
        XCTAssertEqual(reopened, first)
        XCTAssertEqual(store.openTabs.count, 1)
        XCTAssertEqual(store.editorPath, root.appendingPathComponent("one.swift").path)
        XCTAssertEqual(store.editorText, "let one = 1\n")
        XCTAssertEqual(store.editorOriginal, "let one = 1\n")
        XCTAssertFalse(store.hasUnsavedEdits)
    }

    func testCleanTabReplacementPreservesOtherFilesAndPanels() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        try Data("let three = 3\n".utf8).write(to: root.appendingPathComponent("three.swift"))
        let first = try await store.openFileTab("one.swift")
        store.editorText = "unsaved one"
        let second = try await store.openFileTab("two.swift")
        let third = try await store.openFileTab("three.swift")
        XCTAssertEqual(third, second)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(store.openTabs.count, 2)
        XCTAssertEqual(store.buffer(for: first)?.text, "unsaved one")
        XCTAssertEqual(store.editorPath, root.appendingPathComponent("three.swift").path)

        let existing = try await store.openFileTab("one.swift")
        XCTAssertEqual(existing, first)
        XCTAssertEqual(store.openTabs.count, 2)
        XCTAssertEqual(store.editorText, "unsaved one")
        XCTAssertEqual(store.buffer(for: second)?.path, root.appendingPathComponent("three.swift").path)

        store.editorText = store.editorOriginal
        store.openPanel(.changes)
        let changes = store.selectedTabID
        let reopened = try await store.openFileTab("two.swift")
        XCTAssertEqual(reopened, first)
        XCTAssertEqual(store.openTabs.count, 3)
        XCTAssertEqual(store.selectedPanel, .editor)
        XCTAssertEqual(store.buffer(for: second)?.path, root.appendingPathComponent("three.swift").path)
        XCTAssertTrue(store.openTabs.contains { $0.id == changes && $0.kind == .changes })
        XCTAssertEqual(store.editorText, "let two = 2\n")
        XCTAssertFalse(store.hasUnsavedEdits)
    }

    func testSaveFinishesInItsOwnBufferAfterSwitchingTabs() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = try await store.openFileTab("one.swift")
        store.editorText = "saved one"
        let second = try await store.openFileTab("two.swift")
        store.selectTab(first)
        store.saveFile()
        store.selectTab(second)
        store.editorText = "unsaved two"
        for _ in 0..<100 where store.buffer(for: first)?.isDirty == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.error)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("one.swift")), "saved one")
        XCTAssertEqual(store.buffer(for: first)?.original, "saved one")
        XCTAssertEqual(store.editorOriginal, "let two = 2\n")
        XCTAssertEqual(store.editorText, "unsaved two")
    }

    func testWorkspaceToolsRejectInvalidRequestsWithoutOpeningTabs() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let approvals = ApprovalCoordinator(runID: UUID(), emit: { _ in XCTFail("Tab navigation does not require permission") })
        let tools = AgentTools(files: store.fileService(path: root.path), project: root.path, browser: store.browser, workspace: store, reviewer: FixtureToolSafetyReviewer(), approvals: approvals, rootInstructions: "").registry
        let first = try await store.openFileTab("one.swift")
        let initialTabs = store.openTabs
        for arguments in [#"{"kind":"missing"}"#, #"{"kind":"editor","path":12}"#, #"{"kind":"changes","path":"one.swift"}"#, #"{"kind":"editor","url":"https://example.com"}"#, #"{"kind":"browser","url":"file:///etc/passwd"}"#, #"{"kind":"editor","path":"../outside.swift"}"#, #"{"kind":"editor","path":"missing.swift"}"#] {
            do { _ = try await tools.perform(ToolCall(id: UUID().uuidString, name: "workspace_open_tab", arguments: arguments)); XCTFail("Invalid request accepted: \(arguments)") }
            catch {}
        }
        XCTAssertEqual(store.openTabs, initialTabs)
        XCTAssertEqual(store.selectedTabID, first)
        XCTAssertEqual(store.editorPath, root.appendingPathComponent("one.swift").path)
        XCTAssertEqual(store.editorText, "let one = 1\n")
        XCTAssertFalse(store.hasUnsavedEdits)
        XCTAssertFalse(store.browser.hasCreatedWebView)
        XCTAssertThrowsError(try store.selectWorkspaceTab(UUID()))
        XCTAssertThrowsError(try store.closeWorkspaceTab(UUID()))
    }

    func testUndoRestoresReplacedFileWithoutChangingTheSelectedBuffer() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = try await store.openFileTab("one.swift")
        store.editorText = "saved one"
        store.saveFile()
        for _ in 0..<100 where store.editorDirty || store.checkpoints.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.editorDirty)
        XCTAssertEqual(store.checkpoints.count, 1)
        let second = try await store.openFileTab("two.swift")
        XCTAssertEqual(second, first)
        store.undoFile()
        for _ in 0..<100 where !store.checkpoints.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.selectedTabID, second)
        XCTAssertEqual(store.editorPath, root.appendingPathComponent("two.swift").path)
        XCTAssertEqual(store.editorText, "let two = 2\n")
        XCTAssertEqual(store.editorOriginal, "let two = 2\n")
        XCTAssertTrue(store.checkpoints.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("one.swift")), "let one = 1\n")
        XCTAssertNil(store.error)
    }

    func testAgentCannotStopAUserTerminalByClosingItsTab() throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.openPanel(.terminal)
        let id = try XCTUnwrap(store.selectedTabID)
        XCTAssertTrue(store.terminal.running)
        XCTAssertThrowsError(try store.closeWorkspaceTab(id))
        XCTAssertTrue(store.terminal.running)
        XCTAssertEqual(store.selectedTabID, id)
        try store.closeTab(id)
        XCTAssertFalse(store.terminal.running)
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor])
    }

    func testAgentCanOpenSelectAndCloseTabsThroughTheNativeHarness() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceTabModel(), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        harness.onEvent = { if case .approval = $0 { XCTFail("Opening tabs must not request approval") } }
        let config = ModelConfiguration(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: "")
        let history = try await harness.run(configuration: config, messages: [], files: store.fileService(path: root.path), project: root.path, transport: model, browser: store.browser, workspace: store)
        let names = await model.toolNames
        XCTAssertTrue(Set(WorkspaceTabTools.definitions.map(\.name)).isSubset(of: names))
        XCTAssertEqual(history.filter { $0.role == "tool" }.count, 5)
        XCTAssertEqual(history.last?.text, "Showing changes.")
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor, .changes])
        XCTAssertEqual(store.selectedPanel, .changes)
        XCTAssertTrue(store.showWorkspacePanel)
        XCTAssertFalse(store.browser.hasCreatedWebView)
    }

    func testBrowserTabReopensLazilyAndTabsStayWithinTheirProject() throws {
        let (root, store) = try fixture(), (otherRoot, other) = try fixture()
        defer { store.shutdown(); other.shutdown(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        store.browser.onAgentUse?()
        let browserID = try XCTUnwrap(store.selectedTabID)
        XCTAssertEqual(store.selectedPanel, .browser)
        XCTAssertEqual(other.openTabs.map(\.kind), [.editor])
        store.browser.address = "localhost:3000"
        try store.closeTab(browserID)
        XCTAssertEqual(store.browser.address, "")
        XCTAssertFalse(store.browser.hasCreatedWebView)
        store.browser.onAgentUse?()
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor, .browser])
        XCTAssertNotEqual(store.selectedTabID, browserID)
        XCTAssertFalse(store.browser.hasCreatedWebView)
    }
}
