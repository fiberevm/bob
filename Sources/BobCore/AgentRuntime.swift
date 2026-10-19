import Foundation

public enum RuntimeEvent {
    case text(String)
    case activity(String)
    case tool(ToolActivity)
    case history([ModelMessage])
    case usage(TokenUsageRecord)
    case context(ContextUsage)
    case backendSession(String)
    case steered
}

public struct ToolRegistry {
    private let handlers: [String: @Sendable (ToolCall) async throws -> ToolResult]
    let beforeSampling: @Sendable () async -> Void
    let afterCompaction: @Sendable () async -> Void
    public let definitions: [ToolDefinition]
    private let review: (@Sendable (ToolCall, [ModelMessage]) async throws -> ToolSafetyAssessment)?
    public var reviewsTools: Bool { review != nil }
    public init(definitions: [ToolDefinition], beforeSampling: @escaping @Sendable () async -> Void = {}, afterCompaction: @escaping @Sendable () async -> Void = {}, execute: @escaping @Sendable (ToolCall) async throws -> String) {
        self.init(definitions: definitions, beforeSampling: beforeSampling, afterCompaction: afterCompaction, perform: { ToolResult(text: try await execute($0)) })
    }
    public init(definitions: [ToolDefinition], beforeSampling: @escaping @Sendable () async -> Void = {}, afterCompaction: @escaping @Sendable () async -> Void = {}, review: (@Sendable (ToolCall, [ModelMessage]) async throws -> ToolSafetyAssessment)? = nil, perform: @escaping @Sendable (ToolCall) async throws -> ToolResult) {
        self.definitions = definitions
        self.beforeSampling = beforeSampling
        self.afterCompaction = afterCompaction
        self.review = review
        handlers = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, perform) })
    }
    public func execute(_ call: ToolCall) async throws -> String {
        try await perform(call).text
    }
    public func perform(_ call: ToolCall, history: [ModelMessage] = [], onReview: (ToolSafetyAssessment) async throws -> Void = { _ in }, beforeExecution: () async throws -> Void = {}) async throws -> ToolResult {
        guard let handler = handlers[call.name] else { throw BobError.message("Unknown tool: \(call.name)") }
        try Task.checkCancellation()
        if let review {
            let assessment = try await review(call, history)
            try Task.checkCancellation()
            try await onReview(assessment)
            if assessment.outcome == .deny { throw ToolSafetyDenial(assessment) }
        }
        try Task.checkCancellation()
        try await beforeExecution()
        return try await handler(call)
    }
}

/// Owns conversation and execution state. No UI or browser views live in this actor.
public actor AgentRuntime {
    private var active = false
    public init() {}
    public func run(runID: UUID, messages: [ModelMessage], system: String, client: any ModelTransport,
                    tools: ToolRegistry, journal: TurnJournal? = nil, context: ContextManager = ContextManager(),
                    input: AgentInput = AgentInput(), emit: @escaping @Sendable (RuntimeEvent) async -> Void) async throws -> [ModelMessage] {
        guard !active else { throw BobError.message("This agent is already running.") }
        active = true
        defer { active = false }
        var history = ConversationHistory.repaired(messages)
        var uncertain = Set<String>()
        try await journal?.begin(runID: runID, history: history, preserveAudit: true)
        await emit(.context(context.usage(history, system: system, tools: tools.definitions)))
        do {
            while true {
                try Task.checkCancellation()
                let updates = input.takePending()
                if !updates.isEmpty {
                    history = ConversationHistory.repaired(history, uncertain: uncertain)
                    history += updates
                    try await journal?.replace(history)
                    await emit(.history(history)); await emit(.steered)
                }
                let current = history
                let prepared: [ModelMessage]
                do {
                    prepared = try await input.interruptible {
                        try await context.prepare(current, system: system, tools: tools.definitions, client: client, onCompact: {
                            await emit(.activity("Compacting context"))
                        }, onUsage: { usage in
                            let record = TokenUsageRecord(usage: usage)
                            try await journal?.recordUsage(record)
                            await emit(.usage(record))
                        })
                    }
                } catch is AgentSteered { continue }
                if prepared != history {
                    try await journal?.replace(prepared)
                    history = prepared
                    await tools.afterCompaction()
                    await emit(.history(history))
                }
                await emit(.activity("Thinking"))
                await emit(.context(context.usage(history, system: system, tools: tools.definitions)))
                await tools.beforeSampling()
                let streaming = RuntimeTextBuffer()
                let response: ModelMessage
                let samplingHistory = history
                do {
                    response = try await input.interruptible {
                        try await client.complete(messages: samplingHistory, system: system, tools: tools.definitions) { text in
                            guard !input.hasPending else { return }
                            await streaming.append(text)
                            await emit(.text(text))
                        }
                    }
                } catch is AgentSteered {
                    let streamedText = await streaming.text
                    if !streamedText.isEmpty {
                        let partial = ModelMessage(role: "assistant", text: streamedText)
                        history.append(partial); try await journal?.append(partial)
                    }
                    continue
                }
                let streamedText = await streaming.text
                if let usage = response.usage {
                    let record = TokenUsageRecord(usage: usage)
                    try await journal?.recordUsage(record)
                    await emit(.usage(record))
                }
                if input.hasPending { continue }
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !response.toolCalls.isEmpty else {
                    throw BobError.message("The model completed without a reply or tool call. Try again or choose another model.")
                }
                if response.text.hasPrefix(streamedText), response.text.count > streamedText.count {
                    await emit(.text(String(response.text.dropFirst(streamedText.count))))
                }
                let previousIDs = Set(history.flatMap(\.toolCalls).map(\.id))
                let ids = response.toolCalls.map(\.id)
                guard ids.allSatisfy({ !$0.isEmpty && !previousIDs.contains($0) }), Set(ids).count == ids.count else {
                    throw BobError.message("The model returned missing or duplicate tool-call IDs. No tools from this response were run.")
                }
                history.append(response)
                try await journal?.append(response)
                await emit(.history(history))
                await emit(.context(context.usage(history, system: system, tools: tools.definitions)))
                try Task.checkCancellation()
                if response.toolCalls.isEmpty {
                    try await journal?.finish()
                    return history
                }
                for call in response.toolCalls {
                    try Task.checkCancellation()
                    if input.hasPending { break }
                    var activity = ToolActivity(call: call)
                    activity.reviewing = tools.reviewsTools
                    await emit(.tool(activity))
                    let output: ToolResult
                    var failed = false
                    do {
                        output = try await tools.perform(call, history: history, onReview: { assessment in
                            // Persist the decision before allowing a tool handler to run.
                            try await journal?.reviewed(call, assessment: assessment)
                            activity.review = assessment; activity.reviewing = false
                            await emit(.tool(activity))
                        }, beforeExecution: {
                            try input.checkPending()
                            // Reviewing alone cannot create an uncertain side effect.
                            try await journal?.started(call)
                            uncertain.insert(call.id)
                        })
                    }
                    catch is AgentSteered {
                        let text = "Aborted because the user steered the agent. Earlier completed operations remain in the conversation."
                        activity.finish(output: text, cancelled: true)
                        await emit(.tool(activity))
                        history.append(.init(role: "tool", text: text, toolCallID: call.id))
                        uncertain.remove(call.id)
                        try await journal?.append(history.last!)
                        break
                    }
                    catch is CancellationError {
                        activity.finish(output: "Interrupted during execution. Inspect current state before repeating this operation.", cancelled: true)
                        await emit(.tool(activity))
                        throw CancellationError()
                    }
                    catch { failed = true; output = ToolResult(text: "Tool error: \(error.localizedDescription)") }
                    activity.finish(output: String(output.text.prefix(80_000)), failed: failed)
                    await emit(.tool(activity))
                    let result = ModelMessage(role: "tool", text: String(output.text.prefix(80_000)), toolCallID: call.id, images: Array(output.images.prefix(1)))
                    history.append(result)
                    uncertain.remove(call.id)
                    try await journal?.append(result)
                    let bounded = ConversationHistory.limitingImages(history)
                    if bounded != history { history = bounded; try await journal?.replace(history) }
                    await emit(.history(history))
                    await emit(.context(context.usage(history, system: system, tools: tools.definitions)))
                }
            }
        } catch {
            history = ConversationHistory.repaired(history, uncertain: uncertain)
            history += input.takePending()
            await emit(.history(history))
            // Leave a readable recovery record even when cancellation interrupted a tool.
            try await journal?.replace(history)
            try await journal?.finish()
            throw error
        }
    }
}

private actor RuntimeTextBuffer {
    private(set) var text = ""
    func append(_ value: String) { text += value }
}
