import XCTest
@testable import BobCore

final class StreamTests: XCTestCase {
    func testSplitUnicodeAndMultipleJSONEvents() throws {
        var parser = JSONLineBuffer()
        let data = Data("{\"text\":\"👋\"}\n{\"ok\":true}\n".utf8)
        var result: [[String: Any]] = []
        for byte in data { result += try parser.append(Data([byte])) }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["text"] as? String, "👋")
        XCTAssertEqual(result[1]["ok"] as? Bool, true)
    }
    func testSSEMultilineAndComments() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: ": keepalive"))
        XCTAssertNil(parser.consume(line: "event: message"))
        XCTAssertNil(parser.consume(line: "data: first"))
        XCTAssertNil(parser.consume(line: "data: second"))
        XCTAssertEqual(parser.consume(line: ""), "first\nsecond")
        XCTAssertNil(parser.consume(line: ""))
    }
    func testResponsesCompletionPreservesReasoningAndToolCalls() throws {
        var stream = ModelStreamAccumulator(provider: .chatgpt)
        XCTAssertEqual(try stream.consume(#"{"type":"response.output_text.delta","delta":"Looking"}"#), "Looking")
        _ = try stream.consume(#"{"type":"response.completed","response":{"output":[{"type":"reasoning","id":"r1","encrypted_content":"opaque","summary":[]},{"type":"function_call","id":"f1","call_id":"c1","name":"read_file","arguments":"{\"path\":\"GOAL.md\"}"}]}}"#)
        let response = try stream.result()
        XCTAssertEqual(response.toolCalls.first?.id, "c1")
        let input = try ModelClient.responsesInput([response, ModelMessage(role: "tool", text: "content", toolCallID: "c1")])
        XCTAssertEqual(input[0]["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(input[2]["call_id"] as? String, "c1")
    }
    func testTruncatedAndFailedStreamsAreNotSuccess() throws {
        var stream = ModelStreamAccumulator(provider: .chatgpt)
        _ = try stream.consume(#"{"type":"response.output_text.delta","delta":"partial"}"#)
        XCTAssertThrowsError(try stream.result())
        XCTAssertThrowsError(try stream.consume(#"{"type":"response.failed","response":{"error":{"message":"quota reached"}}}"#))
    }
    func testOutputItemsSurviveACompletionWithoutAggregateOutput() throws {
        var stream = ModelStreamAccumulator(provider: .chatgpt)
        XCTAssertEqual(try stream.consume(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"Hello from the completed item."}]}}"#), "Hello from the completed item.")
        _ = try stream.consume(#"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","call_id":"read1","name":"read_file","arguments":"{\"path\":\"README.md\"}"}}"#)
        _ = try stream.consume(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        let result = try stream.result()
        XCTAssertEqual(result.text, "Hello from the completed item.")
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
        XCTAssertEqual(result.providerItems.count, 2)
    }
    func testFinalTextReconcilesDeltasWithoutDuplicatingTheReply() throws {
        var stream = ModelStreamAccumulator(provider: .openai)
        var visible = try stream.consume(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hel"}"#) ?? ""
        visible += try stream.consume(#"{"type":"response.output_text.done","output_index":0,"content_index":0,"text":"Hello"}"#) ?? ""
        visible += try stream.consume(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}"#) ?? ""
        visible += try stream.consume(#"{"type":"response.completed","response":{"output":[{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}]}}"#) ?? ""
        XCTAssertEqual(visible, "Hello")
        XCTAssertEqual(try stream.result().text, visible)
    }
    func testCompletionOnlyAndRefusalRepliesAreVisible() throws {
        for part in [#"{"type":"output_text","text":"Final reply"}"#, #"{"type":"refusal","refusal":"Cannot help with that"}"#] {
            var stream = ModelStreamAccumulator(provider: .chatgpt)
            let delta = try stream.consume("{\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[\(part)]}]}}")
            XCTAssertFalse(try stream.result().text.isEmpty)
            XCTAssertEqual(try stream.result().text, delta)
        }
    }
    func testEmptyCompletedResponseIsAnError() throws {
        var stream = ModelStreamAccumulator(provider: .chatgpt)
        _ = try stream.consume(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        XCTAssertThrowsError(try stream.result()) { error in XCTAssertTrue(error.localizedDescription.contains("without a reply")) }
    }
    func testAnthropicToolArgumentsAcrossDeltas() throws {
        var stream = ModelStreamAccumulator(provider: .claude)
        _ = try stream.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool1","name":"list_files","input":{}}}"#)
        _ = try stream.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#)
        _ = try stream.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\".\"}"}}"#)
        _ = try stream.consume(#"{"type":"message_stop"}"#)
        XCTAssertEqual(try stream.result().toolCalls.first?.arguments, #"{"path":"."}"#)
    }
    func testCompatibleToolFragmentsAndFinishReason() throws {
        var stream = ModelStreamAccumulator(provider: .compatible)
        _ = try stream.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call1","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}"#)
        _ = try stream.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"README.md\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        let call = try XCTUnwrap(stream.result().toolCalls.first)
        XCTAssertEqual(call.id, "call1")
        XCTAssertEqual(call.arguments, #"{"path":"README.md"}"#)
        var incomplete = ModelStreamAccumulator(provider: .compatible)
        XCTAssertThrowsError(try incomplete.consume(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#))
    }
    func testAnthropicCombinesToolResultsIntoOneUserMessage() {
        let calls = [ToolCall(id: "a", name: "read_file", arguments: "{}"), ToolCall(id: "b", name: "list_files", arguments: "{}")]
        let input = ModelClient.anthropicInput([ModelMessage(role: "assistant", toolCalls: calls), ModelMessage(role: "tool", text: "A", toolCallID: "a"), ModelMessage(role: "tool", text: "B", toolCallID: "b")])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual((input[1]["content"] as? [[String: Any]])?.count, 2)
    }
    func testEndpointValidation() throws {
        XCTAssertEqual(try CompatibleEndpoint.url(base: "http://localhost:11434/v1/", resource: "chat/completions").absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNoThrow(try CompatibleEndpoint.url(base: "https://example.com/api/v1", resource: "models"))
        for base in ["http://example.com/v1", "file:///etc", "https://key@example.com", "https://example.com?key=secret", "https://example.com/#frag"] {
            XCTAssertThrowsError(try CompatibleEndpoint.url(base: base, resource: "models"))
        }
    }
}

final class WorkspaceTests: XCTestCase {
    var directory: URL!
    var files: WorkspaceFiles!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bob-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = WorkspaceFiles(root: directory, checkpointDirectory: directory.appendingPathComponent(".checkpoints"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testTraversalAndSymlinkEscapeAreRejected() async throws {
        do { _ = try await files.resolve("../outside"); XCTFail("Traversal was allowed") } catch {}
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: directory.deletingLastPathComponent())
        do { _ = try await files.resolve("escape/outside"); XCTFail("Symlink escape was allowed") } catch {}
        do { _ = try await files.resolve(".git/config"); XCTFail("Git metadata was allowed") } catch {}
        _ = try await files.resolve("safe/new/file.swift")
    }
    func testUndoExistingAndNewFilesSurvivesRestart() async throws {
        try Data("before".utf8).write(to: directory.appendingPathComponent("file.txt"))
        try await files.write("file.txt", text: "after", expected: "before")
        try await files.write("new.txt", text: "new")
        let restored = WorkspaceFiles(root: directory, checkpointDirectory: directory.appendingPathComponent(".checkpoints"))
        _ = try await restored.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.txt").path))
        _ = try await restored.undo()
        let text = try await restored.read("file.txt")
        XCTAssertEqual(text, "before")
    }
    func testUndoProtectsExternalChanges() async throws {
        try await files.write("file.txt", text: "agent")
        try Data("external".utf8).write(to: directory.appendingPathComponent("file.txt"))
        do { _ = try await files.undo(); XCTFail("Overwrote external work") } catch {}
        let text = try await files.read("file.txt")
        XCTAssertEqual(text, "external")
    }
    func testSaveProtectsStaleEditorBuffer() async throws {
        try Data("external".utf8).write(to: directory.appendingPathComponent("file.txt"))
        do { try await files.write("file.txt", text: "new", expected: "stale"); XCTFail("Overwrote external work") } catch {}
    }
    func testPersistentWorkspaceRoundTrip() throws {
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        var session = Session(projectPath: directory.path, provider: .compatible)
        session.messages = [Message(role: .user, text: "hello")]
        session.turns = [ModelMessage(role: "user", text: "hello")]
        try persistence.save(WorkspaceSnapshot(sessions: [session], selectedSessionID: session.id, settings: ProviderSettings()))
        let restored = try persistence.load()
        XCTAssertEqual(restored.selectedSessionID, session.id)
        XCTAssertEqual(restored.sessions[0].turns, session.turns)
        let permissions = try FileManager.default.attributesOfItem(atPath: persistence.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testProcessDrainsBothPipesAndHonorsCancellation() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf out; printf err >&2"])
        XCTAssertEqual(result.output, "out"); XCTAssertEqual(result.error, "err")
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation did not throw") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testCancellationStopsShellChildrenHoldingPipesOpen() async throws {
        let start = Date()
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/bin/sleep 20 & wait"]) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation did not throw") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}
