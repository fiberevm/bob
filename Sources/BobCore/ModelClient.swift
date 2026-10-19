import Foundation

public struct ModelConfiguration {
    public var provider: ProviderKind
    public var model: String
    public var baseURL: String
    public var token: String
    public var reasoningEffort: String?
    public init(provider: ProviderKind, model: String, baseURL: String, token: String, reasoningEffort: String? = nil) {
        self.provider = provider; self.model = model; self.baseURL = baseURL; self.token = token
        self.reasoningEffort = reasoningEffort
    }
}

public struct ToolDefinition {
    public let name: String
    public let description: String
    public let parameters: [String: Any]
    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public protocol ModelTransport {
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage
}

public struct ModelClient: ModelTransport {
    public let configuration: ModelConfiguration
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let onRetry: @Sendable (String) async -> Void
    public init(configuration: ModelConfiguration, session: URLSession = .shared, retryPolicy: RetryPolicy = RetryPolicy(), onRetry: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.configuration = configuration; self.session = session; self.retryPolicy = retryPolicy; self.onRetry = onRetry
    }

    public func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        var attempt = 0
        var visibleText = ""
        while true {
            try Task.checkCancellation()
            let prefix = visibleText
            var pendingReplay = ""
            var checkingReplay = !prefix.isEmpty
            var input = messages
            if !prefix.isEmpty {
                // Only text survives a broken stream. No unfinished tool calls or provider items
                // are sent back, and no tool is executed until a complete response is returned.
                input.append(ModelMessage(role: "assistant", text: prefix))
                input.append(ModelMessage(role: "user", text: "The connection was interrupted during the preceding assistant response. Continue exactly where it ended, without repeating the text already shown. Any tool calls from the interrupted response were discarded and were not executed; issue any needed tool calls again in full."))
            }
            do {
                var response = try await request(messages: input, system: system, tools: tools) { text in
                    var delta = text
                    if checkingReplay {
                        pendingReplay += text
                        // Providers sometimes replay the saved prefix despite the continuation
                        // instruction. Hold matching chunks until we can suppress that replay.
                        if prefix.hasPrefix(pendingReplay) {
                            if pendingReplay == prefix { checkingReplay = false; pendingReplay = "" }
                            return
                        }
                        if pendingReplay.hasPrefix(prefix) {
                            delta = String(pendingReplay.dropFirst(prefix.count))
                        } else { delta = pendingReplay }
                        pendingReplay = ""
                        checkingReplay = false
                    }
                    visibleText += delta
                    if !delta.isEmpty { await onText(delta) }
                }
                // A successful continuation can itself be a short prefix of the prior
                // text (for example, a repeated word). Do not silently drop that text.
                if !pendingReplay.isEmpty {
                    visibleText += pendingReplay
                    await onText(pendingReplay)
                }
                response.text = visibleText
                if !prefix.isEmpty && !response.providerItems.isEmpty {
                    // Responses API history prefers providerItems over text. Keep completed
                    // reasoning/tool items, but replace message items with the canonical text
                    // so future turns see the same response as the user (without replay).
                    var items = try response.providerItems.compactMap {
                        try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                    }
                    let messageIndex = items.firstIndex { $0["type"] as? String == "message" } ?? items.count
                    items.removeAll { $0["type"] as? String == "message" }
                    if !visibleText.isEmpty {
                        items.insert(["role": "assistant", "content": visibleText], at: min(messageIndex, items.count))
                    }
                    response.providerItems = try items.map {
                        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
                    }
                }
                return response
            } catch {
                try Task.checkCancellation()
                guard let delay = retryPolicy.delay(error: error, attempt: attempt) else { throw error }
                attempt += 1
                await onRetry("Reconnecting · \(attempt)/\(retryPolicy.maxRetries)")
                try await retryPolicy.sleep(delay)
            }
        }
    }
    private func request(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        guard configuration.provider != .claudeCode else { throw BobError.message("Claude subscription chats must use the Claude Code backend.") }
        guard !configuration.model.isEmpty else { throw BobError.message("Choose a model in Settings or enter a model ID beside the provider selector.") }
        let responses = configuration.provider == .chatgpt || configuration.provider == .openai
        let anthropic = configuration.provider == .claude
        let resource = anthropic ? "messages" : responses ? "responses" : "chat/completions"
        let url = try CompatibleEndpoint.url(base: configuration.baseURL, resource: resource)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if anthropic {
            request.setValue(configuration.token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !configuration.token.isEmpty { request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": configuration.model, "stream": true]
        if let effort = configuration.reasoningEffort {
            if responses { body["reasoning"] = ["effort": effort] }
            else if anthropic { body["output_config"] = ["effort": effort] }
            else { body["reasoning_effort"] = effort }
        }
        if responses {
            body["store"] = false
            body["instructions"] = system
            body["include"] = ["reasoning.encrypted_content"]
            body["input"] = try Self.responsesInput(messages)
            let functions = tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters, "strict": false] as [String: Any] }
            if configuration.provider == .chatgpt && !functions.isEmpty {
                body["tools"] = [["type": "namespace", "name": "bob", "description": "Project, browser, and desktop tools", "tools": functions]]
            } else { body["tools"] = functions }
        } else if anthropic {
            body["system"] = system; body["max_tokens"] = 8192
            body["messages"] = Self.anthropicInput(messages)
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
        } else {
            body["messages"] = [["role": "system", "content": system]] + Self.chatInput(messages)
            if !tools.isEmpty {
                body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] as [String: Any] }
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw BobError.message("The provider returned an invalid HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count >= 8192 { break } }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (object?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            let code = (object?["error"] as? [String: Any])?["code"] as? String ?? ""
            let type = (object?["error"] as? [String: Any])?["type"] as? String ?? ""
            let quota = ["insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded"].contains(code) || type == "insufficient_quota"
            throw ModelHTTPError(message: "\(configuration.provider.title) HTTP \(http.statusCode): \(detail)", retryable: [401, 408, 429, 500, 502, 503, 504].contains(http.statusCode) && !quota, retryAfter: RetryPolicy.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        var accumulator = ModelStreamAccumulator(provider: configuration.provider)
        var parser = SSEParser(), line = Data()
        // Frame the actual SSE bytes, including blank lines and split UTF-8 sequences.
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                let value = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                line.removeAll(keepingCapacity: true)
                if let payload = parser.consume(line: value) {
                    if let delta = try accumulator.consume(payload) { await onText(delta) }
                }
            } else {
                line.append(byte)
                if line.count > 2 * 1024 * 1024 { throw BobError.message("The provider sent an oversized stream event.") }
            }
        }
        if !line.isEmpty { _ = parser.consume(line: String(decoding: line, as: UTF8.self)) }
        if let payload = parser.consume(line: ""), let delta = try accumulator.consume(payload) { await onText(delta) }
        return try accumulator.result()
    }

    public static func responsesInput(_ messages: [ModelMessage]) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            if !message.providerItems.isEmpty {
                result += try message.providerItems.compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            } else if message.role == "tool" {
                let output: Any = (message.images ?? []).isEmpty ? message.text : [["type": "input_text", "text": message.text]] + (message.images ?? []).map { ["type": "input_image", "image_url": $0.dataURL, "detail": "original"] }
                result.append(["type": "function_call_output", "call_id": message.toolCallID ?? "", "output": output])
            } else {
                if !(message.images ?? []).isEmpty {
                    let content: [[String: Any]] = [["type": "input_text", "text": message.text]] + (message.images ?? []).map { ["type": "input_image", "image_url": $0.dataURL] }
                    result.append(["role": message.role, "content": content])
                } else if !message.text.isEmpty { result.append(["role": message.role, "content": message.text]) }
                result += message.toolCalls.map { ["type": "function_call", "call_id": $0.id, "name": $0.name, "arguments": $0.arguments] }
            }
        }
        return result
    }
    public static func chatInput(_ messages: [ModelMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = [], pendingImages: [[String: Any]] = []
        func flushImages() {
            if !pendingImages.isEmpty { result.append(["role": "user", "content": pendingImages]); pendingImages = [] }
        }
        for message in messages {
            if message.role != "tool" { flushImages() }
            var object: [String: Any] = ["role": message.role, "content": message.text]
            if let id = message.toolCallID { object["tool_call_id"] = id }
            if !message.toolCalls.isEmpty {
                object["tool_calls"] = message.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any] }
            }
            if message.role == "user", let images = message.images, !images.isEmpty {
                object["content"] = [["type": "text", "text": message.text]] + images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] as [String: Any] }
            }
            result.append(object)
            for image in message.role == "tool" ? (message.images ?? []) : [] {
                pendingImages += [["type": "text", "text": "Screenshot returned by tool \(message.toolCallID ?? "observation"):"], ["type": "image_url", "image_url": ["url": image.dataURL]]]
            }
        }
        flushImages()
        return result
    }
    public static func anthropicInput(_ messages: [ModelMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            let role = message.role == "tool" ? "user" : message.role
            var blocks: [[String: Any]] = []
            if message.role == "tool" {
                let content: Any = (message.images ?? []).isEmpty ? message.text : [["type": "text", "text": message.text]] + (message.images ?? []).map { ["type": "image", "source": ["type": "base64", "media_type": $0.mimeType, "data": $0.data.base64EncodedString()]] as [String: Any] }
                blocks = [["type": "tool_result", "tool_use_id": message.toolCallID ?? "", "content": content]]
            }
            else {
                if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
                blocks += (message.images ?? []).map { ["type": "image", "source": ["type": "base64", "media_type": $0.mimeType, "data": $0.data.base64EncodedString()]] }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) ?? [:]
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
            }
            if let last = result.last, last["role"] as? String == role {
                result[result.count - 1]["content"] = (last["content"] as? [[String: Any]] ?? []) + blocks
            } else { result.append(["role": role, "content": blocks]) }
        }
        return result
    }
}

public struct ModelStreamAccumulator {
    private let provider: ProviderKind
    private var text = ""
    private var calls: [Int: ToolCall] = [:]
    private var providerItems: [String] = []
    private var responseItems: [Int: [String: Any]] = [:]
    private var textParts: [String: String] = [:]
    private var usage: ModelUsage?
    private var finished = false
    public init(provider: ProviderKind) { self.provider = provider }
    public mutating func consume(_ payload: String) throws -> String? {
        if payload == "[DONE]" { return nil }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { throw BobError.message(error["message"] as? String ?? "Provider stream error.") }
        if let values = object["usage"] as? [String: Any] {
            usage = ModelUsage(inputTokens: values["input_tokens"] as? Int ?? values["prompt_tokens"] as? Int ?? usage?.inputTokens ?? 0, outputTokens: values["output_tokens"] as? Int ?? values["completion_tokens"] as? Int ?? usage?.outputTokens ?? 0)
        }
        var delta: String?
        if provider == .chatgpt || provider == .openai {
            switch object["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta":
                delta = object["delta"] as? String
                if let delta { textParts[textKey(object), default: ""] += delta }
            case "response.output_text.done", "response.refusal.done":
                delta = try completedText(object["text"] as? String ?? object["refusal"] as? String ?? "", key: textKey(object))
            case "response.content_part.done":
                let part = object["part"] as? [String: Any] ?? [:]
                delta = try completedText(part["text"] as? String ?? part["refusal"] as? String ?? "", key: textKey(object))
            case "response.output_item.added", "response.output_item.done":
                if let item = object["item"] as? [String: Any] {
                    let index = object["output_index"] as? Int ?? 0
                    responseItems[index] = item
                    if object["type"] as? String == "response.output_item.done" { delta = try completedItemText(item, index: index) }
                }
            case "response.function_call_arguments.done":
                let index = object["output_index"] as? Int ?? 0
                if let arguments = object["arguments"] as? String { responseItems[index]?["arguments"] = arguments }
            case "response.completed":
                let response = object["response"] as? [String: Any] ?? [:]
                if let status = response["status"] as? String, status != "completed" { throw BobError.message("The provider stopped with status \(status). The response is incomplete.") }
                if let values = response["usage"] as? [String: Any] { usage = ModelUsage(inputTokens: values["input_tokens"] as? Int ?? 0, outputTokens: values["output_tokens"] as? Int ?? 0) }
                let items = response["output"] as? [[String: Any]] ?? []
                for (index, item) in items.enumerated() { responseItems[index] = item }
                var remaining = ""
                for index in responseItems.keys.sorted() {
                    let item = responseItems[index]!
                    remaining += try completedItemText(item, index: index) ?? ""
                    if item["type"] as? String == "function_call" {
                        calls[index] = ToolCall(id: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "", arguments: item["arguments"] as? String ?? "{}")
                    }
                }
                if !remaining.isEmpty { delta = remaining }
                providerItems = try responseItems.keys.sorted().map { String(decoding: try JSONSerialization.data(withJSONObject: responseItems[$0]!), as: UTF8.self) }
                finished = true
            case "response.failed", "response.incomplete", "error":
                let response = object["response"] as? [String: Any] ?? [:]
                let error = response["error"] as? [String: Any] ?? [:]
                let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                throw BobError.message(error["message"] as? String ?? object["message"] as? String ?? reason.map { "The response is incomplete: \($0)." } ?? "The provider did not complete the response.")
            default: break
            }
        } else if provider == .claude {
            switch object["type"] as? String {
            case "message_start":
                if let values = (object["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    usage = ModelUsage(inputTokens: (values["input_tokens"] as? Int ?? 0) + (values["cache_read_input_tokens"] as? Int ?? 0) + (values["cache_creation_input_tokens"] as? Int ?? 0), outputTokens: values["output_tokens"] as? Int ?? 0)
                }
            case "content_block_start":
                let block = object["content_block"] as? [String: Any] ?? [:]
                if block["type"] as? String == "tool_use" {
                    calls[object["index"] as? Int ?? 0] = ToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", arguments: "")
                }
            case "content_block_delta":
                let block = object["delta"] as? [String: Any] ?? [:]
                delta = block["text"] as? String
                if let partial = block["partial_json"] as? String { calls[object["index"] as? Int ?? 0]?.arguments += partial }
            case "message_delta":
                let stop = (object["delta"] as? [String: Any])?["stop_reason"] as? String
                if stop == "max_tokens" { throw BobError.message("Claude reached its output limit. The response is incomplete.") }
            case "message_stop": finished = true
            default: break
            }
        } else {
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
            let chunk = choice["delta"] as? [String: Any] ?? [:]
            delta = chunk["content"] as? String
            for call in chunk["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                let function = call["function"] as? [String: Any] ?? [:]
                var current = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                current.id += call["id"] as? String ?? ""
                current.name += function["name"] as? String ?? ""
                current.arguments += function["arguments"] as? String ?? ""
                calls[index] = current
            }
            if let reason = choice["finish_reason"] as? String {
                guard reason == "stop" || reason == "tool_calls" else { throw BobError.message("Model stopped with \(reason); the response is incomplete.") }
                finished = true
            }
        }
        if let delta { text += delta }
        return delta
    }
    public func result() throws -> ModelMessage {
        guard finished else { throw IncompleteModelStream() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else {
            throw BobError.message("The model completed without a reply or tool call. Try again or choose another model.")
        }
        return ModelMessage(role: "assistant", text: text, toolCalls: calls.keys.sorted().compactMap { calls[$0] }, providerItems: providerItems, usage: usage)
    }
    private func textKey(_ event: [String: Any]) -> String {
        "\(event["output_index"] as? Int ?? 0):\(event["content_index"] as? Int ?? 0)"
    }
    private mutating func completedText(_ full: String, key: String) throws -> String? {
        let received = textParts[key] ?? ""
        guard full.hasPrefix(received) else { throw BobError.message("The provider returned inconsistent response text.") }
        textParts[key] = full
        let remainder = String(full.dropFirst(received.count))
        return remainder.isEmpty ? nil : remainder
    }
    private mutating func completedItemText(_ item: [String: Any], index: Int) throws -> String? {
        var remainder = ""
        for (partIndex, part) in (item["content"] as? [[String: Any]] ?? []).enumerated() {
            if let full = part["text"] as? String ?? part["refusal"] as? String {
                remainder += try completedText(full, key: "\(index):\(partIndex)") ?? ""
            }
        }
        return remainder.isEmpty ? nil : remainder
    }
}
