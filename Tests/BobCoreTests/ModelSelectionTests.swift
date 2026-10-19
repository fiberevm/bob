import XCTest
@testable import Bob
@testable import BobCore

private final class CatalogFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let model: [String: String]
        if request.url?.host == "api.openai.com" {
            model = ["id": "api-model", "display_name": "API Model"]
        } else if request.url?.host == "api.anthropic.com" {
            model = ["id": "claude-model", "display_name": "Claude Model"]
        } else { model = ["id": "local-model", "display_name": "Local Model"] }
        let data = try! JSONSerialization.data(withJSONObject: ["data": [model]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class ModelSelectionTests: XCTestCase {
    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testCatalogGroupsOnlyConnectedProvidersAndSurvivesRestart() async throws {
        let suite = "bob-model-tests-\(UUID())", session = fixtureSession()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        let connections = ConnectionPreferences(defaults: defaults, session: session)
        XCTAssertTrue(connections.modelGroups(including: nil).isEmpty)
        connections.settings.baseURL = "https://local.example/v1"
        connections.settings.apiModel = "custom-local-model"
        connections.savedCredentials(openAI: "fixture-key", claude: "", compatible: "", configureCompatible: true)
        _ = try await connections.loadModels(provider: .openai, baseURL: "https://api.openai.com/v1", token: "fixture-key", accountID: nil)
        _ = try await connections.loadModels(provider: .compatible, baseURL: connections.settings.baseURL, token: "", accountID: nil)
        let groups = connections.modelGroups(including: nil)
        XCTAssertEqual(groups.map(\.provider), [.openai, .compatible])
        XCTAssertEqual(groups[0].models.map(\.name), ["API Model"])
        XCTAssertEqual(groups[1].models.map(\.id), ["local-model", "custom-local-model"])
        XCTAssertFalse(String(decoding: defaults.data(forKey: "providers.catalogs")!, as: UTF8.self).contains("fixture-key"))

        let reopened = ConnectionPreferences(defaults: defaults, session: session)
        reopened.savedCredentials(openAI: "fixture-key", claude: "", compatible: "", configureCompatible: false)
        XCTAssertEqual(reopened.models(for: .openai).first?.name, "API Model")
        XCTAssertEqual(reopened.modelGroups(including: nil).map(\.provider), [.openai, .compatible])
        reopened.settings.baseURL = "https://another.example/v1"
        XCTAssertTrue(reopened.models(for: .compatible).isEmpty)
        reopened.savedCredentials(openAI: "changed-key", claude: "", compatible: "", configureCompatible: false)
        XCTAssertTrue(reopened.models(for: .openai).isEmpty)
        reopened.savedCredentials(openAI: "", claude: "", compatible: "", configureCompatible: false)
        XCTAssertEqual(reopened.modelGroups(including: nil).map(\.provider), [.compatible])
    }

    func testSelectingAModelUpdatesProviderAtomicallyAndPreservesDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-selection-\(UUID())")
        let suite = "bob-model-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connections = ConnectionPreferences(defaults: defaults)
        connections.savedCredentials(openAI: "fixture-key", claude: "fixture-key", compatible: "", configureCompatible: false)
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"), connections: connections)
        let first = try XCTUnwrap(store.selectedID)
        store.draft = "Keep this prompt"
        store.selectModel(AvailableModel(id: "claude-model"), provider: .claude)
        XCTAssertEqual(store.selectedID, first)
        XCTAssertEqual(store.selected?.provider, .claude)
        XCTAssertEqual(store.selected?.model, "claude-model")
        XCTAssertEqual(store.draft, "Keep this prompt")
        XCTAssertEqual(store.sessions.count, 1)

        store.mutate(first) { $0.messages.append(Message(role: .user, text: "Existing Claude conversation")) }
        store.selectModel(AvailableModel(id: "api-model"), provider: .openai)
        XCTAssertNotEqual(store.selectedID, first)
        XCTAssertEqual(store.selected?.provider, .openai)
        XCTAssertEqual(store.selected?.model, "api-model")
        XCTAssertEqual(store.draft, "Keep this prompt")
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions.first(where: { $0.id == first })?.messages.first?.text, "Existing Claude conversation")
        let second = store.selectedID
        store.selectModel(AvailableModel(id: "another-api-model"), provider: .openai)
        XCTAssertEqual(store.selectedID, second)
        XCTAssertEqual(store.selected?.model, "another-api-model")
        store.send()
        XCTAssertTrue(store.isRunning)
        store.selectModel(AvailableModel(id: "claude-model"), provider: .claude)
        XCTAssertEqual(store.selected?.provider, .openai)
        XCTAssertEqual(store.selected?.model, "another-api-model")
        store.shutdown()
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isRunning)
    }

    func testChatGPTCatalogFiltersHiddenAndDuplicateModels() throws {
        let data = Data(#"{"models":[{"slug":"listed","display_name":"Listed Model","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"listed","visibility":"list"},{"slug":"","visibility":"list"}]}"#.utf8)
        XCTAssertEqual(try ModelCatalog.parse(data, provider: .chatgpt), [AvailableModel(id: "listed", name: "Listed Model")])
    }

    func testEffortCatalogPreservesModelCapabilitiesAndLegacyCaches() throws {
        let data = Data(#"{"models":[{"slug":"custom-reasoner","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"persistent"},{"effort":"high"}]},{"slug":"gpt-6.1-sol","visibility":"list","supported_reasoning_levels":[]}]}"#.utf8)
        let models = try ModelCatalog.parse(data, provider: .chatgpt)
        XCTAssertEqual(ModelReasoning.supportedEfforts(provider: .chatgpt, model: models[0]), ["low", "high", "persistent"])
        XCTAssertTrue(ModelReasoning.supportedEfforts(provider: .chatgpt, model: models[1]).isEmpty)
        let oldCache = try JSONDecoder().decode(AvailableModel.self, from: Data(#"{"id":"gpt-6.1-sol","name":"Sol"}"#.utf8))
        XCTAssertEqual(ModelReasoning.supportedEfforts(provider: .chatgpt, model: oldCache), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(ModelReasoning.supportedEfforts(provider: .openai, model: AvailableModel(id: "gpt-4o")).isEmpty)
        XCTAssertEqual(ModelReasoning.supportedEfforts(provider: .claude, model: AvailableModel(id: "claude-sonnet-4-6")), ["low", "medium", "high", "max"])
    }

    func testEffortSelectionPersistsAndRejectsUnsupportedOrRunningChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-effort-\(UUID())")
        let suite = "bob-effort-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connections = ConnectionPreferences(defaults: defaults)
        let storage = root.appendingPathComponent("state")
        let store = AppStore(projectPath: root.path, storageDirectory: storage, connections: connections)
        store.newSession(provider: .compatible); store.setModel("gpt-6.1-sol")
        store.draft = "Keep my prompt"
        let id = store.selectedID
        store.selectReasoningEffort("xhigh")
        XCTAssertEqual(store.selectedReasoningEffort, "xhigh")
        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.draft, "Keep my prompt")
        store.selectReasoningEffort("unsupported")
        XCTAssertEqual(store.selectedReasoningEffort, "xhigh")
        store.send(); store.selectReasoningEffort("low")
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.selectedReasoningEffort, "xhigh")
        store.shutdown()
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isRunning)
        let reopened = AppStore(projectPath: root.path, storageDirectory: storage, connections: connections)
        defer { reopened.shutdown() }
        XCTAssertEqual(reopened.selectedReasoningEffort, "xhigh")
        reopened.selectReasoningEffort(nil)
        XCTAssertNil(reopened.selected?.reasoningEffort)
        reopened.setModel("local-model")
        XCTAssertTrue(reopened.availableReasoningEfforts.isEmpty)
        reopened.selectReasoningEffort("high")
        XCTAssertNil(reopened.selectedReasoningEffort)
    }

    func testOlderChatsWithoutEffortStillDecode() throws {
        let data = Data(#"{"id":"3D9FA4B2-1A26-4C29-957E-5BA93BDA975D","title":"Older chat","projectPath":"/tmp/project","provider":"chatgpt","model":"gpt-6.1-sol","messages":[],"updatedAt":0,"turns":[]}"#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(session.title, "Older chat")
        XCTAssertNil(session.reasoningEffort)
    }
}
