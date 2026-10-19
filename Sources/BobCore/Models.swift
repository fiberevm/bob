import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatgpt, openai, claudeCode, claude, compatible
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .openai: return "OpenAI API"
        case .claudeCode: return "Claude"
        case .claude: return "Claude API"
        case .compatible: return "OpenAI-compatible"
        }
    }
    public var symbol: String {
        switch self {
        case .chatgpt, .openai: return "sparkles"
        case .claude, .claudeCode: return "sun.max"
        case .compatible: return "network"
        }
    }
}

public struct Message: Codable, Identifiable, Equatable {
    public enum Role: String, Codable { case user, assistant, activity, error }
    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    public var tool: ToolActivity?
    public var isSteering: Bool?
    public init(role: Role, text: String, id: UUID = UUID(), tool: ToolActivity? = nil, isSteering: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.date = Date(); self.tool = tool
        self.isSteering = isSteering ? true : nil
    }
}

public struct Session: Codable, Identifiable {
    public var id: UUID = UUID()
    public var title: String = "New Chat"
    public var projectPath: String
    public var provider: ProviderKind = .chatgpt
    public var model: String = ""
    public var reasoningEffort: String?
    public var plan: String?
    public var usageRecords: [String: ModelUsage]?
    public var contextUsage: ContextUsage?
    public var claudeCodeSessionID: String?
    public var messages: [Message] = []
    public var updatedAt: Date = Date()
    public var turns: [ModelMessage] = []
    public init(projectPath: String, provider: ProviderKind = .chatgpt) {
        self.projectPath = projectPath; self.provider = provider
    }
    public var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
}

public struct ProviderSettings: Codable, Equatable {
    public var baseURL: String = "http://localhost:11434/v1"
    public var apiModel: String = ""
    public var openAIModel: String = ""
    public var chatGPTModel: String = ""
    public var claudeModel: String = ""
    public var claudeCodeModel: String?
    public init() {}
    public subscript(provider: ProviderKind) -> String {
        get {
            switch provider {
            case .chatgpt: return chatGPTModel
            case .openai: return openAIModel
            case .claude: return claudeModel
            case .claudeCode: return claudeCodeModel ?? ""
            case .compatible: return apiModel
            }
        }
        set {
            switch provider {
            case .chatgpt: chatGPTModel = newValue
            case .openai: openAIModel = newValue
            case .claude: claudeModel = newValue
            case .claudeCode: claudeCodeModel = newValue
            case .compatible: apiModel = newValue
            }
        }
    }
}

public struct ToolCall: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}

public struct ModelMessage: Codable, Equatable, Sendable {
    public var role: String
    public var text: String
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var providerItems: [String]
    public var usage: ModelUsage?
    public var images: [ModelImage]?
    public var userMessageID: UUID?
    public init(role: String, text: String = "", toolCalls: [ToolCall] = [], toolCallID: String? = nil, providerItems: [String] = [], usage: ModelUsage? = nil, images: [ModelImage] = [], userMessageID: UUID? = nil) {
        self.role = role; self.text = text; self.toolCalls = toolCalls; self.toolCallID = toolCallID
        self.providerItems = providerItems
        self.usage = usage
        self.images = images.isEmpty ? nil : images
        self.userMessageID = userMessageID
    }
}

public struct ModelImage: Codable, Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
    public init(data: Data, mimeType: String = "image/jpeg", width: Int, height: Int) {
        self.data = data; self.mimeType = mimeType; self.width = width; self.height = height
    }
    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

public struct ToolResult: Sendable {
    public let text: String
    public let images: [ModelImage]
    public init(text: String, images: [ModelImage] = []) { self.text = text; self.images = images }
}

public struct ModelUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}

public struct WorkspaceSnapshot: Codable {
    public var sessions: [Session]
    public var selectedSessionID: UUID?
    public var settings: ProviderSettings
    public init(sessions: [Session], selectedSessionID: UUID?, settings: ProviderSettings) {
        self.sessions = sessions; self.selectedSessionID = selectedSessionID; self.settings = settings
    }
}

public struct WorkspacePersistence {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> WorkspaceSnapshot {
        try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: url))
    }
    public func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum BobError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
