import Foundation
import Combine
import CryptoKit
import BobCore

struct ProviderModelGroup: Identifiable {
    let provider: ProviderKind
    let models: [AvailableModel]
    var id: ProviderKind { provider }
}

@MainActor final class ConnectionPreferences: ObservableObject {
    static let shared = ConnectionPreferences()
    @Published var settings: ProviderSettings {
        didSet { if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "providers.settings") } }
    }
    @Published private var catalogs: [String: CachedCatalog] = [:]
    @Published private var connected = Set<ProviderKind>()
    let auth: ChatGPTAuth
    let claude: ClaudeCodeConnection
    let usage: AccountUsageStore
    private let defaults: UserDefaults
    private let session: URLSession
    private var keys: [ProviderKind: String] = [:]
    private var restored = false
    private var authObservation: AnyCancellable?
    private var claudeObservation: AnyCancellable?
    private var usageObservation: AnyCancellable?
    private var usageIdentityObservation: AnyCancellable?
    private var requests: [String: Task<[AvailableModel], Error>] = [:]
    private struct CachedCatalog: Codable {
        let models: [AvailableModel]
        let date: Date
    }

    init(defaults: UserDefaults = .standard, auth: ChatGPTAuth? = nil, session: URLSession = .shared, claude: ClaudeCodeConnection? = nil, usage: AccountUsageStore? = nil) {
        self.defaults = defaults
        self.session = session
        self.auth = auth ?? ChatGPTAuth(defaults: defaults)
        self.claude = claude ?? ClaudeCodeConnection()
        self.usage = usage ?? AccountUsageStore()
        if let data = defaults.data(forKey: "providers.settings"), let saved = try? JSONDecoder().decode(ProviderSettings.self, from: data) { settings = saved }
        else { settings = ProviderSettings() }
        if let data = defaults.data(forKey: "providers.catalogs"), let saved = try? JSONDecoder().decode([String: CachedCatalog].self, from: data) { catalogs = saved }
        authObservation = self.auth.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in await self?.refreshCatalogs() }
        }
        claudeObservation = self.claude.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        usageObservation = self.usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        usageIdentityObservation = self.auth.$selectedID.removeDuplicates().dropFirst().sink { [weak self] _ in self?.usage.reset() }
    }

    func restoreConnections() {
        guard !restored else { return }
        restored = true
        for provider in [ProviderKind.openai, .claude, .compatible] {
            keys[provider] = (try? SecretStore.read(provider.rawValue)) ?? ""
        }
        updateConnectedProviders()
    }

    func savedCredentials(openAI: String, claude: String, compatible: String, configureCompatible: Bool) {
        restored = true
        keys = [.openai: openAI, .claude: claude, .compatible: compatible]
        if configureCompatible { defaults.set(true, forKey: "providers.compatibleConfigured") }
        updateConnectedProviders()
    }

    private func updateConnectedProviders() {
        var providers = Set([ProviderKind.openai, .claude].filter { !credential(for: $0).isEmpty })
        if defaults.bool(forKey: "providers.compatibleConfigured") || !settings.apiModel.isEmpty || !credential(for: .compatible).isEmpty {
            if (try? CompatibleEndpoint.url(base: settings.baseURL, resource: "models")) != nil { providers.insert(.compatible) }
        }
        connected = providers
    }

    private func credential(for provider: ProviderKind) -> String { (keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private func baseURL(for provider: ProviderKind) -> String {
        switch provider {
        case .chatgpt, .openai: return "https://api.openai.com/v1"
        case .claude: return "https://api.anthropic.com/v1"
        case .claudeCode: return ""
        case .compatible: return settings.baseURL
        }
    }
    private func context(provider: ProviderKind, baseURL: String, token: String, accountID: String?) -> String {
        let identity = provider == .chatgpt ? accountID ?? "" : token
        let digest = SHA256.hash(data: Data("\(baseURL)|\(identity)".utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(provider.rawValue):\(digest)"
    }
    private func currentContext(for provider: ProviderKind) -> String {
        context(provider: provider, baseURL: baseURL(for: provider), token: credential(for: provider), accountID: auth.selectedID)
    }
    var connectedProviders: [ProviderKind] {
        ProviderKind.allCases.filter { provider in
            if provider == .claudeCode { return claude.isConnected }
            return provider == .chatgpt ? auth.selected != nil : connected.contains(provider)
        }
    }
    func models(for provider: ProviderKind) -> [AvailableModel] {
        if provider == .claudeCode { return claude.models }
        return catalogs[currentContext(for: provider)]?.models ?? []
    }
    func defaultModel(for provider: ProviderKind) -> String {
        let configured = settings[provider].trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? models(for: provider).first?.id ?? "" : configured
    }
    func modelGroups(including session: Session?) -> [ProviderModelGroup] {
        connectedProviders.map { provider in
            var models = models(for: provider)
            for id in [settings[provider], session?.provider == provider ? session?.model ?? "" : ""] {
                let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty && !models.contains(where: { $0.id == id }) { models.append(AvailableModel(id: id)) }
            }
            return ProviderModelGroup(provider: provider, models: models)
        }
    }

    func loadModels(provider: ProviderKind, baseURL: String, token: String, accountID: String?) async throws -> [AvailableModel] {
        if provider == .claudeCode {
            await claude.refresh()
            guard claude.isConnected else { throw BobError.message(claude.error ?? "Connect Claude Code in Settings.") }
            if let error = claude.error { throw BobError.message(error) }
            return claude.models
        }
        let id = context(provider: provider, baseURL: baseURL, token: token, accountID: accountID)
        if let pending = requests[id] { return try await pending.value }
        let session = self.session
        let task = Task { try await ModelCatalog.load(provider: provider, baseURL: baseURL, token: token, session: session) }
        requests[id] = task
        defer { requests[id] = nil }
        let models = try await task.value
        remember(models, context: id)
        return models
    }
    private func remember(_ models: [AvailableModel], context: String) {
        catalogs[context] = CachedCatalog(models: models, date: Date())
        // Bound metadata retained for old accounts and endpoints.
        if catalogs.count > 12 {
            let keep = Set(catalogs.sorted { $0.value.date > $1.value.date }.prefix(12).map(\.key))
            catalogs = catalogs.filter { keep.contains($0.key) }
        }
        if let data = try? JSONEncoder().encode(catalogs) { defaults.set(data, forKey: "providers.catalogs") }
    }
    func refreshCatalogs() async {
        restoreConnections()
        if !claude.checked { await claude.refresh() }
        await withTaskGroup(of: Void.self) { group in
            for provider in connectedProviders {
                group.addTask { await self.refreshCatalog(provider) }
            }
        }
    }
    private func refreshCatalog(_ provider: ProviderKind) async {
        if provider == .claudeCode { return }
        let id = currentContext(for: provider)
        if let cache = catalogs[id], Date().timeIntervalSince(cache.date) < 600 { return }
        let base = baseURL(for: provider), account = auth.selectedID
        do {
            let token = provider == .chatgpt ? try await auth.accessToken() : credential(for: provider)
            _ = try await loadModels(provider: provider, baseURL: base, token: token, accountID: account)
        } catch {
            // Keep cached/manual choices usable; Settings exposes refresh errors.
        }
    }
}
