import XCTest
@testable import BobCore

private final class ModelFixtureProtocol: URLProtocol {
    static var fixture: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.fixture?(request) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Exercise framing independently of network packet boundaries.
        for offset in stride(from: 0, to: data.count, by: 7) {
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 7, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPTests: XCTestCase {
    private func run(provider: ProviderKind, stream: String, effort: String? = nil, check: @escaping (URLRequest) -> Void) async throws -> ModelMessage {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ModelFixtureProtocol.fixture = nil }
        ModelFixtureProtocol.fixture = { request in check(request); return Data(stream.utf8) }
        let client = ModelClient(configuration: ModelConfiguration(provider: provider, model: "fixture", baseURL: "http://localhost/v1", token: "test-token", reasoningEffort: effort), session: session)
        return try await client.complete(messages: [ModelMessage(role: "user", text: "Hello")], system: "Test", tools: WorkspaceTools.definitions, onText: { _ in })
    }
    func testResponsesHTTPHeadersAndSSE() async throws {
        let stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 👋\"}\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\r\n\r\n"
        let result = try await run(provider: .chatgpt, stream: stream) { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            let body: Data
            if let data = request.httpBody { body = data }
            else if let input = request.httpBodyStream {
                input.open(); defer { input.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            } else { XCTFail("Missing request body"); return }
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["store"] as? Bool, false)
            let tools = object?["tools"] as? [[String: Any]]
            XCTAssertEqual(tools?.first?["type"] as? String, "namespace")
            XCTAssertEqual(tools?.first?["name"] as? String, "bob")
            XCTAssertEqual((tools?.first?["tools"] as? [[String: Any]])?.count, 4)
        }
        XCTAssertEqual(result.text, "Hello 👋")
    }
    func testAnthropicHTTPHeadersAndSSE() async throws {
        let stream = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        let result = try await run(provider: .claude, stream: stream) { request in
            XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        }
        XCTAssertEqual(result.text, "Hello")
    }
    func testCompletedItemHTTPStreamProducesAReplyWithoutTextDeltas() async throws {
        let stream = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"Visible reply 👋"}]}}

        data: {"type":"response.completed","response":{"status":"completed","output":[]}}


        """
        let result = try await run(provider: .chatgpt, stream: stream) { _ in }
        XCTAssertEqual(result.text, "Visible reply 👋")
        XCTAssertEqual(result.providerItems.count, 1)
    }
    func testCompatibleHTTPAndIncompleteResponse() async throws {
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"
        do {
            _ = try await run(provider: .compatible, stream: stream) { request in XCTAssertEqual(request.url?.path, "/v1/chat/completions") }
            XCTFail("An incomplete stream was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("completed")) }
    }

    func testEffortUsesEachProvidersRequestSchemaAndAutoOmitsIt() async throws {
        for provider in ProviderKind.allCases {
            let stream: String
            switch provider {
            case .chatgpt, .openai:
                stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Ready\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"
            case .claude:
                stream = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Ready\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            case .compatible:
                stream = "data: {\"choices\":[{\"delta\":{\"content\":\"Ready\"},\"finish_reason\":\"stop\"}]}\n\n"
            case .claudeCode: continue // Local binary protocol, covered by ClaudeCodeTests.
            }
            for effort in [nil, "high"] as [String?] {
                _ = try await run(provider: provider, stream: stream, effort: effort) { request in
                    let body = self.requestBody(request)
                    let responsesEffort = (body["reasoning"] as? [String: Any])?["effort"] as? String
                    let claudeEffort = (body["output_config"] as? [String: Any])?["effort"] as? String
                    let compatibleEffort = body["reasoning_effort"] as? String
                    XCTAssertEqual(responsesEffort, provider == .chatgpt || provider == .openai ? effort : nil)
                    XCTAssertEqual(claudeEffort, provider == .claude ? effort : nil)
                    XCTAssertEqual(compatibleEffort, provider == .compatible ? effort : nil)
                }
            }
        }
    }
    private func requestBody(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
