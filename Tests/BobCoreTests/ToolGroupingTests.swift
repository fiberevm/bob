import XCTest
@testable import BobCore

final class ToolGroupingTests: XCTestCase {
    private func message(_ id: String, name: String = "read_file", path: String = "README.md", running: Bool = false) -> Message {
        let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["path": path]), as: UTF8.self)
        var tool = ToolActivity(call: ToolCall(id: id, name: name, arguments: args))
        if !running { tool.finish(output: "Contents") }
        return Message(role: .activity, text: "", tool: tool)
    }
    private func groups(_ messages: [Message]) -> [ToolActivityGroup] {
        ChatTranscript.items(from: messages).compactMap { item in
            if case .tools(let group) = item { return group }
            return nil
        }
    }
    func testAdjacentCallsGroupAcrossEmptyAssistantPlaceholders() throws {
        let first = message("read1"), second = message("read2", path: "GOAL.md")
        let messages = [Message(role: .user, text: "Inspect"), first, Message(role: .assistant, text: " \n"), second, Message(role: .assistant, text: "Done")]
        let items = ChatTranscript.items(from: messages), group = try XCTUnwrap(groups(messages).first)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(group.id, first.id)
        XCTAssertEqual(group.tools.map(\.id), ["read1", "read2"])
        XCTAssertEqual(group.title, "Explored 2 files")
        XCTAssertEqual(messages[1].tool?.output, "Contents")
    }
    func testVisibleMessagesAndNoticesBreakGroups() {
        let messages = [message("a"), Message(role: .assistant, text: "Checking another file"), message("b"), Message(role: .error, text: "Network failed"), message("c"), Message(role: .activity, text: "Recovered interrupted work"), message("d"), Message(role: .user, text: "New request"), message("e")]
        XCTAssertEqual(groups(messages).map { $0.tools.map(\.id) }, [["a"], ["b"], ["c"], ["d"], ["e"]])
        XCTAssertEqual(ChatTranscript.items(from: messages).count, messages.count)
    }
    func testGrowingAndCompletingAGroupKeepsItsIdentityAndCallOrder() throws {
        var first = message("a", running: true)
        let original = try XCTUnwrap(groups([first]).first)
        first.tool?.finish(output: "First file")
        var second = message("b", path: "GOAL.md", running: true)
        let growing = try XCTUnwrap(groups([first, second]).first)
        XCTAssertEqual(growing.id, original.id)
        XCTAssertEqual(growing.tools.map(\.id), ["a", "b"])
        XCTAssertEqual(growing.activeTool?.id, "b")
        XCTAssertEqual(growing.title, "Exploring 2 files")
        XCTAssertNil(growing.duration)
        second.tool?.finish(output: "Second file")
        let completed = try XCTUnwrap(groups([first, second]).first)
        XCTAssertEqual(completed.id, original.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.title, "Explored 2 files")
        XCTAssertNotNil(completed.duration)
    }
    func testUnsuccessfulAttemptsKeepResultsWithoutFailureNotices() throws {
        var failed = message("failed")
        failed.tool?.finish(output: "Tool error: unreadable", failed: true)
        var next = message("next", path: "GOAL.md", running: true)
        let working = try XCTUnwrap(groups([failed, next]).first)
        XCTAssertEqual(working.status, .running)
        XCTAssertEqual(working.notices, "")
        next.tool?.finish(output: "Done")
        let finished = try XCTUnwrap(groups([failed, next]).first)
        XCTAssertEqual(finished.status, .failed)
        XCTAssertEqual(finished.notices, "")
        next.tool?.finish(output: "The user declined this action.")
        XCTAssertEqual(groups([failed, next]).first?.notices, "1 declined")
        next.tool?.finish(output: "Interrupted", cancelled: true)
        XCTAssertEqual(groups([failed, next]).first?.notices, "1 stopped")
    }
    func testSummaryCountsUniqueFilesAndKeepsMixedToolsTogether() {
        let reads = [message("a"), message("b"), message("c", name: "list_files", path: "Sources")]
        XCTAssertEqual(groups(reads).first?.title, "Explored 1 file, 1 list")
        XCTAssertEqual(groups([message("a", name: "run_command"), message("b", name: "run_command")]).first?.title, "Ran 2 commands")
        XCTAssertEqual(groups([message("a", name: "write_file"), message("b", name: "write_file")]).first?.title, "Edited 1 file")
        XCTAssertEqual(groups([message("a", name: "browser_read"), message("b", name: "browser_scroll")]).first?.title, "Used browser · 2 actions")
        let mixed = groups([message("a"), message("b", name: "workspace_open_tab"), message("c", name: "run_command")])
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed.first?.title, "Used 3 tools")
    }
    func testGroupsRebuildFromSavedMessagesWithoutLosingResults() throws {
        let messages = [message("a"), message("b", path: "GOAL.md")]
        let saved = try JSONEncoder().encode(messages)
        let restored = try JSONDecoder().decode([Message].self, from: saved)
        XCTAssertEqual(ChatTranscript.items(from: restored), ChatTranscript.items(from: messages))
    }
}
