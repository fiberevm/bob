import Foundation

public enum ModelReasoning {
    public static func title(for effort: String?) -> String {
        switch effort {
        case nil: return "Auto"
        case "none": return "None"
        case "xhigh": return "Extra high"
        case let effort?: return effort.capitalized
        }
    }

    /// Prefer the provider's catalog over compatibility defaults. An explicit
    /// empty list means the model does not offer an effort control.
    public static func supportedEfforts(provider: ProviderKind, model: AvailableModel) -> [String] {
        if let advertised = model.reasoningEfforts { return advertised }
        let id = model.id.lowercased()
        if provider == .chatgpt || provider == .openai || provider == .compatible {
            if id.hasPrefix("gpt-6.1-sol") { return ["low", "medium", "high", "xhigh", "max"] }
            if id.contains("-pro") || id.contains("chat") || id.contains("search") || id.hasPrefix("o1-mini") { return [] }
            if ["gpt-5", "gpt-6", "o1", "o3", "o4"].contains(where: { id.hasPrefix($0) }) {
                return ["low", "medium", "high"]
            }
        }
        if provider == .claude || provider == .claudeCode {
            let five = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5-5", "claude-fable-5", "claude-mythos-5", "claude-mythos-preview"]
            if five.contains(where: { id.hasPrefix($0) }) || ["claude-opus-4-7", "claude-opus-4-8"].contains(where: { id.hasPrefix($0) }) {
                return ["low", "medium", "high", "xhigh", "max"]
            }
            if ["claude-opus-4-6", "claude-sonnet-4-6"].contains(where: { id.hasPrefix($0) }) {
                return ["low", "medium", "high", "max"]
            }
            if id.hasPrefix("claude-opus-4-5") { return ["low", "medium", "high"] }
        }
        return []
    }
}
