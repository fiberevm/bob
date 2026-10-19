import XCTest
@testable import BobCore

private final class RetryFixtureProtocol: URLProtocol {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body: String; var error: URLError? }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private(set) static var count = 0
    private(set) static var bodies: [Data] = []
    static func configure(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; count = 0; bodies = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        if let body = request.httpBody { Self.bodies.append(body) }
        else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            Self.bodies.append(data)
        }
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "Unexpected retry") : Self.replies.removeFirst()
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
private actor DelayLog {
    var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { values.append(value) }
}

final class RetryTests: XCTestCase {
    private let completed = "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\"}]}\n\n"
    private func client(provider: ProviderKind = .compatible, policy: RetryPolicy) -> (ModelClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RetryFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        return (ModelClient(configuration: ModelConfiguration(provider: provider, model: "fixture", baseURL: "http://localhost/v1", token: "fixture"), session: session, retryPolicy: policy), session)
    }
    func testRetryAfterIsHonoredBeforeRetryingRateLimit() async throws {
        RetryFixtureProtocol.configure([.init(status: 429, headers: ["Retry-After": "2"], body: "{\"error\":{\"message\":\"rate limit\"}}"), .init(status: 200, body: completed)])
        let delays = DelayLog(), (model, session) = client(policy: RetryPolicy(sleep: { await delays.add($0) }))
        defer { session.invalidateAndCancel() }
        let response = try await model.complete(messages: [], system: "", tools: [], onText: { _ in })
        XCTAssertEqual(response.text, "Done"); XCTAssertEqual(RetryFixtureProtocol.count, 2)
        let recorded = await delays.values; XCTAssertEqual(recorded, [2])
    }
    func testAuthenticationAndQuotaErrorsAreNotRetried() async throws {
        for (status, code) in [(401, "invalid_api_key"), (429, "insufficient_quota")] {
            RetryFixtureProtocol.configure([.init(status: status, body: "{\"error\":{\"code\":\"\(code)\",\"message\":\"blocked\"}}")])
            let (model, session) = client(policy: RetryPolicy(sleep: { _ in XCTFail("Must not retry") }))
            defer { session.invalidateAndCancel() }
            do { _ = try await model.complete(messages: [], system: "", tools: [], onText: { _ in }); XCTFail("Expected failure") } catch {}
            XCTAssertEqual(RetryFixtureProtocol.count, 1)
        }
    }
    private func chunk(_ text: String, finish: Bool = false) -> String {
        let choice: [String: Any] = ["delta": ["content": text], "finish_reason": finish ? "stop" : NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }
    func testIncompleteStreamWithoutVisibleOutputCanRetry() async throws {
        RetryFixtureProtocol.configure([.init(status: 200, body: ": keepalive\n\n"), .init(status: 200, body: completed)])
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        let result = try await model.complete(messages: [], system: "", tools: [], onText: { _ in })
        XCTAssertEqual(result.text, "Done"); XCTAssertEqual(RetryFixtureProtocol.count, 2)
    }
    func testPartialOutputContinuesAndRequestContainsVisibleContext() async throws {
        RetryFixtureProtocol.configure([.init(status: 200, body: chunk("Partial")), .init(status: 200, body: chunk(" answer", finish: true))])
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        var visible = ""
        let result = try await model.complete(messages: [ModelMessage(role: "user", text: "Question")], system: "", tools: [], onText: { visible += $0 })
        XCTAssertEqual(visible, "Partial answer"); XCTAssertEqual(result.text, visible)
        XCTAssertEqual(RetryFixtureProtocol.count, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: RetryFixtureProtocol.bodies[1]) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[messages.count - 2]["content"] as? String, "Partial")
        XCTAssertTrue((messages.last?["content"] as? String)?.contains("Continue exactly where it ended") == true)
    }
    func testReplayAcrossChunksAndRepeatedInterruption() async throws {
        RetryFixtureProtocol.configure([
            .init(status: 200, body: chunk("Hello")),
            .init(status: 200, body: chunk("He") + chunk("llo wor")),
            .init(status: 200, body: chunk("Hello w") + chunk("orld!", finish: true))
        ])
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        var visible = ""
        let result = try await model.complete(messages: [], system: "", tools: [], onText: { visible += $0 })
        XCTAssertEqual(visible, "Hello world!"); XCTAssertEqual(result.text, visible)
        XCTAssertEqual(RetryFixtureProtocol.count, 3)
    }
    func testShortContinuationMatchingPrefixIsNotLost() async throws {
        RetryFixtureProtocol.configure([.init(status: 200, body: chunk("abc")), .init(status: 200, body: chunk("a", finish: true))])
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        var visible = ""
        let result = try await model.complete(messages: [], system: "", tools: [], onText: { visible += $0 })
        XCTAssertEqual(visible, "abca"); XCTAssertEqual(result.text, visible)
    }
    func testFailedStreamToolCallsAreDiscarded() async throws {
        let brokenTool = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"broken","function":{"name":"write_file","arguments":"{"}}]}}]}"# + "\n\n"
        let completeTool = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"fresh","function":{"name":"read_file","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\n"
        RetryFixtureProtocol.configure([.init(status: 200, body: chunk("Looking") + brokenTool), .init(status: 200, body: completeTool)])
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        let result = try await model.complete(messages: [], system: "", tools: [], onText: { _ in })
        XCTAssertEqual(result.text, "Looking")
        XCTAssertEqual(result.toolCalls.map(\.id), ["fresh"])
        XCTAssertFalse(String(decoding: RetryFixtureProtocol.bodies[1], as: UTF8.self).contains("broken"))
    }
    func testPartialOutputSurvivesRetryExhaustion() async throws {
        RetryFixtureProtocol.configure([.init(status: 200, body: chunk("One")), .init(status: 200, body: chunk(" two")), .init(status: 200, body: chunk(" three"))])
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        var visible = ""
        do {
            _ = try await model.complete(messages: [], system: "", tools: [], onText: { visible += $0 })
            XCTFail("Expected incomplete response")
        } catch is IncompleteModelStream {}
        XCTAssertEqual(visible, "One two three")
        XCTAssertEqual(RetryFixtureProtocol.count, 3)
    }
    func testRetriesAreBoundedAndCancellationStopsBackoff() async throws {
        RetryFixtureProtocol.configure(Array(repeating: .init(status: 503, body: "busy"), count: 3))
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        do { _ = try await model.complete(messages: [], system: "", tools: [], onText: { _ in }); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(RetryFixtureProtocol.count, 3)
        RetryFixtureProtocol.configure([.init(status: 503, body: "busy")])
        let waiting = expectation(description: "Backoff")
        let (cancellable, other) = client(policy: RetryPolicy(sleep: { _ in waiting.fulfill(); try await Task.sleep(for: .seconds(30)) }))
        defer { other.invalidateAndCancel() }
        let task = Task { try await cancellable.complete(messages: [], system: "", tools: [], onText: { _ in }) }
        await fulfillment(of: [waiting], timeout: 2); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(RetryFixtureProtocol.count, 1)
    }
    func testRetryAfterDateAndLongServerDeadline() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RetryPolicy.retryAfter("Thu, 01 Jan 1970 00:00:10 GMT", now: now), 10)
        XCTAssertNil(RetryPolicy().delay(error: ModelHTTPError(message: "busy", retryable: true, retryAfter: 3600), attempt: 0))
    }
    func testResponsesContinuationPreservesCanonicalHistoryAndFreshTools() async throws {
        let partial = #"data: {"type":"response.output_text.delta","delta":"Hello"}"# + "\n\n"
        let completed = #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","id":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":" world"}]},{"type":"function_call","call_id":"fresh","name":"read_file","arguments":"{}"}]}}"# + "\n\n"
        RetryFixtureProtocol.configure([.init(status: 200, body: partial), .init(status: 200, body: completed)])
        let (model, session) = client(provider: .openai, policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        var visible = ""
        let result = try await model.complete(messages: [], system: "", tools: [], onText: { visible += $0 })
        XCTAssertEqual(visible, "Hello world"); XCTAssertEqual(result.text, visible)
        XCTAssertEqual(result.toolCalls.map(\.id), ["fresh"])
        let history = try ModelClient.responsesInput([result])
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0]["type"] as? String, "reasoning")
        XCTAssertEqual(history[1]["role"] as? String, "assistant")
        XCTAssertEqual(history[1]["content"] as? String, visible)
        XCTAssertEqual(history[2]["call_id"] as? String, "fresh")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: RetryFixtureProtocol.bodies[1]) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["content"] as? String, "Hello")
    }
    func testClaudeContinuationRetainsPartialText() async throws {
        let partial = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"# + "\n\n"
        let continuation = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"# + "\n\n" + #"data: {"type":"message_stop"}"# + "\n\n"
        RetryFixtureProtocol.configure([.init(status: 200, body: partial), .init(status: 200, body: continuation)])
        let (model, session) = client(provider: .claude, policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        var visible = ""
        let result = try await model.complete(messages: [], system: "", tools: [], onText: { visible += $0 })
        XCTAssertEqual(visible, "Hello world"); XCTAssertEqual(result.text, visible)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: RetryFixtureProtocol.bodies[1]) as? [String: Any])
        let input = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "assistant")
        let blocks = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["text"] as? String, "Hello")
    }
    func testNetworkConnectionLossIsRetryable() async throws {
        RetryFixtureProtocol.configure([.init(status: 200, body: "", error: URLError(.networkConnectionLost)), .init(status: 200, body: completed)])
        let (model, session) = client(policy: RetryPolicy(sleep: { _ in }))
        defer { session.invalidateAndCancel() }
        let result = try await model.complete(messages: [], system: "", tools: [], onText: { _ in })
        XCTAssertEqual(result.text, "Done")
        XCTAssertEqual(RetryFixtureProtocol.count, 2)
    }
    func testProviderUsageIsRecorded() throws {
        var stream = ModelStreamAccumulator(provider: .openai)
        _ = try stream.consume(#"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Done"}]}],"usage":{"input_tokens":123,"output_tokens":45}}}"#)
        XCTAssertEqual(try stream.result().usage, ModelUsage(inputTokens: 123, outputTokens: 45))
    }
}
