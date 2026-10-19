import Foundation

public struct TokenUsageRecord: Codable, Equatable, Sendable {
    public let id: String
    public let usage: ModelUsage
    public init(id: String = UUID().uuidString, usage: ModelUsage) { self.id = id; self.usage = usage }
}

public struct ContextUsage: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case localBudget, provider }
    public var tokens: Int
    public var budget: Int?
    public var isEstimated: Bool
    public var source: Source
    public init(tokens: Int, budget: Int?, isEstimated: Bool, source: Source) {
        self.tokens = max(0, tokens); self.budget = budget.flatMap { $0 > 0 ? $0 : nil }
        self.isEstimated = isEstimated; self.source = source
    }
    public var fraction: Double? { budget.map { min(1, max(0, Double(tokens) / Double($0))) } }
}

extension ModelUsage {
    public static let zero = ModelUsage(inputTokens: 0, outputTokens: 0)
    public func adding(_ other: ModelUsage) -> ModelUsage {
        func sum(_ first: Int, _ second: Int) -> Int {
            let result = max(0, first).addingReportingOverflow(max(0, second))
            return result.overflow ? Int.max : result.partialValue
        }
        return ModelUsage(inputTokens: sum(inputTokens, other.inputTokens), outputTokens: sum(outputTokens, other.outputTokens))
    }
    public static func claude(_ object: [String: Any]) -> ModelUsage? {
        guard object["input_tokens"] is Int || object["output_tokens"] is Int else { return nil }
        return ModelUsage(inputTokens: max(0, object["input_tokens"] as? Int ?? 0), outputTokens: max(0, object["output_tokens"] as? Int ?? 0))
            .adding(ModelUsage(inputTokens: max(0, object["cache_read_input_tokens"] as? Int ?? 0), outputTokens: 0))
            .adding(ModelUsage(inputTokens: max(0, object["cache_creation_input_tokens"] as? Int ?? 0), outputTokens: 0))
    }
}

extension Session {
    public var totalTokenUsage: ModelUsage? {
        let values = usageRecords.map { Array($0.values) } ?? turns.compactMap(\.usage)
        if values.isEmpty && turns.contains(where: { $0.role == "assistant" }) { return nil }
        return values.reduce(.zero) { $0.adding($1) }
    }
    public mutating func migrateTokenUsage() {
        guard usageRecords == nil else { return }
        usageRecords = Dictionary(uniqueKeysWithValues: turns.enumerated().compactMap { index, message in
            message.usage.map { ("legacy-\(id)-\(index)", $0) }
        })
    }
    public mutating func recordTokenUsage(_ record: TokenUsageRecord) {
        migrateTokenUsage()
        usageRecords?[record.id] = record.usage
    }
}
