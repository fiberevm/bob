import Foundation

public enum ConversationHistory {
    public static func limitingImages(_ history: [ModelMessage], keep: Int = 2) -> [ModelMessage] {
        var remaining = keep
        return history.reversed().map { message in
            var copy = message
            if let images = message.images, !images.isEmpty {
                if remaining > 0 { copy.images = Array(images.prefix(remaining)); remaining -= copy.images?.count ?? 0 }
                else { copy.images = nil; copy.text += "\n[Earlier screenshot omitted. Capture fresh state before acting.]" }
            }
            return copy
        }.reversed()
    }
    /// Every tool call must have exactly one result, even after interruption.
    public static func repaired(_ messages: [ModelMessage], uncertain: Set<String> = []) -> [ModelMessage] {
        var result: [ModelMessage] = [], index = 0
        while index < messages.count {
            let message = messages[index]
            index += 1
            if message.role == "tool" { continue } // Drop orphan results.
            result.append(message)
            guard !message.toolCalls.isEmpty else { continue }
            var outputs: [String: ModelMessage] = [:]
            while index < messages.count, messages[index].role == "tool" {
                if let id = messages[index].toolCallID { outputs[id] = messages[index] }
                index += 1
            }
            for call in message.toolCalls {
                result.append(outputs[call.id] ?? ModelMessage(role: "tool", text: uncertain.contains(call.id)
                    ? "Interrupted during execution. This operation may have completed. Inspect the current state before attempting it again."
                    : "Aborted before execution.", toolCallID: call.id))
            }
        }
        return result
    }
}

public struct RecoveredTurn {
    public let runID: UUID
    public let history: [ModelMessage]
    public let interrupted: Bool
    public let reviews: [String: ToolSafetyAssessment]
    public let delegatedTools: [ToolActivity]
    public let backendSessionID: String?
    public let usageRecords: [String: ModelUsage]
}

/// A checkpoint at turn start followed by synchronized, append-only execution events.
/// Recovery never replays tools. A started call without a result is explicitly uncertain.
public actor TurnJournal {
    private struct Record: Codable {
        enum Kind: String, Codable { case start, message, toolReviewed, toolStarted, delegatedTool, replace, finish, backendSession, usage }
        var kind: Kind
        var runID: UUID?
        var history: [ModelMessage]?
        var message: ModelMessage?
        var callID: String?
        var review: ToolSafetyAssessment?
        var reviews: [String: ToolSafetyAssessment]?
        var activity: ToolActivity?
        var delegatedTools: [ToolActivity]?
        var backendSessionID: String?
        var usageRecords: [String: ModelUsage]?
    }
    public let url: URL
    private var runID: UUID?
    private var reviews: [String: ToolSafetyAssessment] = [:]
    private var delegatedTools: [ToolActivity] = []
    private var backendSessionID: String?
    private var usageRecords: [String: ModelUsage] = [:]
    public init(url: URL) { self.url = url }

    public func begin(runID: UUID, history: [ModelMessage], reviews: [String: ToolSafetyAssessment] = [:], delegatedTools: [ToolActivity] = [], preserveAudit: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reviews = preserveAudit && self.runID == runID ? self.reviews.merging(reviews) { _, new in new } : reviews
        let delegatedTools = preserveAudit && self.runID == runID && delegatedTools.isEmpty ? self.delegatedTools : delegatedTools
        let usageRecords = self.runID == runID ? self.usageRecords : [:]
        let record = Record(kind: .start, runID: runID, history: history, reviews: reviews, delegatedTools: delegatedTools, backendSessionID: backendSessionID, usageRecords: usageRecords)
        try encoded(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        self.runID = runID
        self.reviews = reviews
        self.delegatedTools = delegatedTools
        self.usageRecords = usageRecords
    }
    public func append(_ message: ModelMessage) throws { try append(Record(kind: .message, message: message)) }
    public func started(_ call: ToolCall) throws { try append(Record(kind: .toolStarted, callID: call.id)) }
    public func recordUsage(_ record: TokenUsageRecord) throws {
        try append(Record(kind: .usage, usageRecords: [record.id: record.usage]))
        usageRecords[record.id] = record.usage
    }
    public func backendSession(_ id: String) throws {
        try append(Record(kind: .backendSession, backendSessionID: id)); backendSessionID = id
    }
    public func reviewed(_ call: ToolCall, assessment: ToolSafetyAssessment) throws {
        try append(Record(kind: .toolReviewed, callID: call.id, review: assessment))
        reviews[call.id] = assessment
    }
    public func delegated(_ activity: ToolActivity) throws {
        guard activity.parentCallID != nil else { throw BobError.message("A delegated action must name its parent call.") }
        try append(Record(kind: .delegatedTool, activity: activity))
        if let index = delegatedTools.firstIndex(where: { $0.id == activity.id }) { delegatedTools[index] = activity }
        else { delegatedTools.append(activity) }
    }
    public func replace(_ history: [ModelMessage]) throws {
        try append(Record(kind: .replace, history: history))
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if bytes > 8 * 1024 * 1024, let runID {
            // Replacing context happens between tools, with no unrecorded running operation.
            // Bound screenshot-heavy logs while preserving an atomic recovery checkpoint.
            let retained = Set(history.flatMap(\.toolCalls).map(\.id))
            try begin(runID: runID, history: history, reviews: reviews.filter { retained.contains($0.key) },
                      delegatedTools: delegatedTools.filter { $0.parentCallID.map(retained.contains) ?? false })
        }
    }
    public func finish() throws { try append(Record(kind: .finish)) }

    private func encoded(_ record: Record) throws -> Data {
        var data = try JSONEncoder().encode(record); data.append(10); return data
    }
    private func append(_ record: Record) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded(record))
        try handle.synchronize()
    }
    public static func recover(from url: URL) throws -> RecoveredTurn? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        // An incomplete last line is a torn append; earlier malformed records are errors.
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        var runID: UUID?, history: [ModelMessage] = [], started = Set<String>(), finished = false
        var reviews: [String: ToolSafetyAssessment] = [:]
        var delegatedTools: [ToolActivity] = []
        var backendSessionID: String?
        var usageRecords: [String: ModelUsage] = [:]
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 { break }
            let record = try JSONDecoder().decode(Record.self, from: Data(line))
            switch record.kind {
            case .start:
                runID = record.runID; history = record.history ?? []; started = []; finished = false; reviews = record.reviews ?? [:]; delegatedTools = record.delegatedTools ?? []; backendSessionID = record.backendSessionID
                usageRecords = record.usageRecords ?? [:]
            case .message:
                if let message = record.message {
                    history.append(message)
                    if let id = message.toolCallID { started.remove(id) }
                }
            case .toolStarted: if let id = record.callID { started.insert(id) }
            case .toolReviewed: if let id = record.callID, let review = record.review { reviews[id] = review }
            case .delegatedTool:
                if let activity = record.activity {
                    if let index = delegatedTools.firstIndex(where: { $0.id == activity.id }) { delegatedTools[index] = activity }
                    else { delegatedTools.append(activity) }
                }
            case .replace: history = record.history ?? []; started = []
            case .finish: finished = true
            case .backendSession: backendSessionID = record.backendSessionID
            case .usage: usageRecords.merge(record.usageRecords ?? [:]) { _, new in new }
            }
        }
        guard let runID else { throw BobError.message("The agent journal has no valid turn checkpoint.") }
        for index in delegatedTools.indices where delegatedTools[index].status == .running {
            delegatedTools[index].finish(output: delegatedTools[index].executionStarted == true
                ? "Interrupted during delegated execution. This action may have completed. Inspect current state before repeating it."
                : "Aborted before delegated execution.", cancelled: true)
        }
        return RecoveredTurn(runID: runID, history: ConversationHistory.repaired(history, uncertain: started), interrupted: !finished, reviews: reviews, delegatedTools: delegatedTools, backendSessionID: backendSessionID, usageRecords: usageRecords)
    }
}
