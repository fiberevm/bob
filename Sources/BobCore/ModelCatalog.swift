import Foundation

public struct AvailableModel: Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let reasoningEfforts: [String]?
    public init(id: String, name: String? = nil, reasoningEfforts: [String]? = nil) {
        self.id = id
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? id
        self.reasoningEfforts = reasoningEfforts
    }
}

public enum ModelCatalog {
    public static func load(provider: ProviderKind, baseURL: String, token: String, session: URLSession = .shared) async throws -> [AvailableModel] {
        guard provider != .claudeCode else { throw BobError.message("Load Claude subscription models through Claude Code.") }
        var request = URLRequest(url: try CompatibleEndpoint.url(base: baseURL, resource: "models"))
        request.timeoutInterval = 20
        if provider == .claude {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BobError.message("Could not load \(provider.title) models. Check the connection in Settings.")
        }
        return try parse(data, provider: provider)
    }

    public static func parse(_ data: Data, provider: ProviderKind) throws -> [AvailableModel] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let entries = object[provider == .chatgpt ? "models" : "data"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return entries.compactMap { item in
            if provider == .chatgpt && item["visibility"] as? String != "list" { return nil }
            guard let id = item["slug"] as? String ?? item["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(id).inserted else { return nil }
            let efforts = (item["supported_reasoning_levels"] as? [Any]).map { levels in
                var seen = Set<String>()
                return levels.compactMap { level -> String? in
                    guard let value = (level as? [String: Any])?["effort"] as? String ?? level as? String,
                          !value.isEmpty, seen.insert(value).inserted else { return nil }
                    return value
                }
            }
            return AvailableModel(id: id, name: item["display_name"] as? String, reasoningEfforts: efforts)
        }
    }
}
