import AppKit
import SwiftUI
import XCTest
@testable import Bob
@testable import BobCore

private actor PlanModel: ModelTransport {
    static let markdown = "# Delivery plan\n\n## Implementation\n- [ ] Build the feature\n- [x] Inspect the project\n\n## Validation\nRun `swift test`.\n"
    private var step = 0
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        XCTAssertTrue(system.contains("workspace_update_plan"))
        XCTAssertTrue(tools.contains { $0.name == "workspace_update_plan" })
        defer { step += 1 }
        if step == 0 {
            let arguments = String(decoding: try JSONEncoder().encode(["markdown": Self.markdown]), as: UTF8.self)
            return ModelMessage(role: "assistant", toolCalls: [.init(id: "write-plan", name: "workspace_update_plan", arguments: arguments)])
        }
        if step == 1 { return ModelMessage(role: "assistant", toolCalls: [.init(id: "read-plan", name: "workspace_read_plan", arguments: "{}")]) }
        XCTAssertEqual(messages.last?.text, Self.markdown)
        return ModelMessage(role: "assistant", text: "The detailed plan is in the Plan tab.")
    }
}

@MainActor final class PlanTests: XCTestCase {
    private func fixture() throws -> (URL, AppStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-plan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state")))
    }

    func testAgentCreatesReadsAndPersistsAPlanThroughTheHarness() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let sessionID = try XCTUnwrap(store.selectedID)
        let history = try await AgentHarness(reviewer: FixtureToolSafetyReviewer()).run(
            configuration: .init(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: ""),
            messages: [.init(role: "user", text: "Create a detailed plan")], files: store.fileService(path: root.path),
            project: root.path, transport: PlanModel(), workspace: store, workspaceSessionID: sessionID)
        XCTAssertEqual(history.filter { $0.role == "tool" }.count, 2)
        XCTAssertEqual(store.selected?.plan, PlanModel.markdown)
        XCTAssertEqual(store.selectedPanel, .plan)
        let tabID = try XCTUnwrap(store.selectedTabID)
        store.openPanel(.plan)
        XCTAssertEqual(store.selectedTabID, tabID)
        _ = try store.closeWorkspaceTab(tabID)
        XCTAssertEqual(store.selectedPanel, .editor)
        XCTAssertEqual(try store.readWorkspacePlan(sessionID: sessionID), PlanModel.markdown)

        let restored = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { restored.shutdown() }
        XCTAssertEqual(try restored.readWorkspacePlan(sessionID: sessionID), PlanModel.markdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PLAN.md").path))
    }

    func testBackgroundPlanToolsRemainBoundToTheirOriginalChat() async throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(store.selectedID)
        _ = try store.updateWorkspacePlan("# First chat", sessionID: first)
        store.mutate(first) { $0.messages.append(Message(role: .user, text: "First request")) }
        store.newSession()
        let second = try XCTUnwrap(store.selectedID)
        _ = try store.updateWorkspacePlan("# Second chat", sessionID: second)
        let approvals = ApprovalCoordinator(runID: UUID()) { _ in XCTFail("Plan updates should not need confirmation") }
        let registry = AgentTools(files: store.fileService(path: root.path), project: root.path, browser: nil,
            workspace: store, workspaceSessionID: second, reviewer: FixtureToolSafetyReviewer(), approvals: approvals, rootInstructions: "").registry
        store.select(first)
        store.openPanel(.changes)
        let visibleTab = store.selectedTabID
        let read = try await registry.perform(.init(id: "read", name: "workspace_read_plan", arguments: "{}"))
        XCTAssertEqual(read.text, "# Second chat")
        _ = try await registry.perform(.init(id: "update", name: "workspace_update_plan", arguments: ##"{"markdown":"# Updated background plan"}"##))
        XCTAssertEqual(store.selectedID, first)
        XCTAssertEqual(store.selectedTabID, visibleTab)
        XCTAssertEqual(store.selected?.plan, "# First chat")
        store.select(second)
        XCTAssertEqual(store.selected?.plan, "# Updated background plan")
    }

    func testInvalidPlanUpdatesPreserveTheSavedDocumentAndLegacyChatsLoad() throws {
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        _ = try store.updateWorkspacePlan("# Keep this plan", sessionID: nil)
        XCTAssertThrowsError(try store.updateWorkspacePlan(String(repeating: "x", count: 200_001), sessionID: nil))
        XCTAssertThrowsError(try store.updateWorkspacePlan("wrong chat", sessionID: UUID()))
        XCTAssertEqual(store.selected?.plan, "# Keep this plan")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.selected!)) as? [String: Any])
        json.removeValue(forKey: "plan")
        let legacy = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.plan)
    }

    func testNativeMarkdownFormatsBlocksLinksChecklistsAndTables() throws {
        let markdown = """
        # Delivery plan

        A **detailed** plan with a [reference](https://example.com/docs).

        - [ ] Pending
        - [x] Complete
          - Nested step

        1. First
        2. Second

        > Check assumptions.

        ```swift
        let ready = true
        ```

        | Step | Outcome |
        | --- | --- |
        | Build | Pass |
        """
        let rendered = PlanMarkdownFormatter.render(markdown)
        let text = rendered.string as NSString
        XCTAssertTrue(rendered.string.hasPrefix("Delivery plan\nA detailed plan"))
        XCTAssertTrue(rendered.string.contains("☐\tPending"))
        XCTAssertTrue(rendered.string.contains("☑\tComplete"))
        XCTAssertTrue(rendered.string.contains("1.\tFirst"))
        XCTAssertTrue(rendered.string.contains("2.\tSecond"))
        let heading = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(heading.pointSize, 28)
        let bold = try XCTUnwrap(rendered.attribute(.font, at: text.range(of: "detailed").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let link = rendered.attribute(.link, at: text.range(of: "reference").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com/docs")
        let codeFont = try XCTUnwrap(rendered.attribute(.font, at: text.range(of: "let ready").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(codeFont.isFixedPitch)
        let nested = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: "Nested step").location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(nested.firstLineHeadIndent, 22)
        let tableStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: "Build").location, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try XCTUnwrap(tableStyle.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(cell.table.numberOfColumns, 2)
        XCTAssertEqual(cell.startingRow, 1)
    }

    func testPlanDisplayIsSelectableReadOnlyAndScrollable() async throws {
        _ = NSApplication.shared
        let (root, store) = try fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let markdown = "# Detailed plan\n\n" + (1...40).map { "## Step \($0)\n\nDescribe the implementation and validation.\n" }.joined(separator: "\n")
        _ = try store.updateWorkspacePlan(markdown, sessionID: nil)
        let host = NSHostingView(rootView: PlanView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        func findText(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        let text = try XCTUnwrap(findText(in: host))
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        XCTAssertTrue(text.string.contains("Step 40"))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        XCTAssertGreaterThan(text.frame.height, scroll.contentSize.height)
    }
}
