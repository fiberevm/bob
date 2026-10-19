import AppKit
import WebKit
import XCTest
@testable import Bob
@testable import BobCore

private actor BrowserScriptedModel: ModelTransport {
    private var responses: [ModelMessage]
    private(set) var tools: Set<String> = []
    init(_ responses: [ModelMessage]) { self.responses = responses }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        self.tools = Set(tools.map(\.name))
        guard !responses.isEmpty else { throw BobError.message("Unexpected model request") }
        return responses.removeFirst()
    }
}

@MainActor private final class FixtureBrowser: AgentBrowser {
    var currentURL = "http://localhost:3000"
    var actions: [String] = []
    func navigate(_ address: String) async throws -> String { actions.append("navigate"); return "Page snapshot" }
    func readPage() async throws -> String { "Page snapshot" }
    func targetDescription(snapshot: String, reference: Int, typing: Bool) async throws -> String { "Message field" }
    func click(snapshot: String, reference: Int) async throws -> String { actions.append("click"); return "Clicked snapshot" }
    func type(snapshot: String, reference: Int, text: String) async throws -> String { actions.append("type:\(text)"); return "Typed snapshot" }
    func scrollPage(direction: String) async throws -> String { "Scrolled snapshot" }
    func cancelAgentOperation() { actions.append("stop") }
}

@MainActor final class BrowserTests: XCTestCase {
    func testAddressesSupportLocalDevelopmentAndRejectOtherSchemes() throws {
        XCTAssertEqual(try BrowserAddress.resolve("example.com/docs").absoluteString, "https://example.com/docs")
        XCTAssertEqual(try BrowserAddress.resolve(" localhost:3000 ").absoluteString, "http://localhost:3000")
        XCTAssertEqual(try BrowserAddress.resolve("127.0.0.1:8080/app").scheme, "http")
        XCTAssertEqual(try BrowserAddress.resolve("[::1]:3000").scheme, "http")
        for invalid in ["", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "https://user:secret@example.com", "not a url"] {
            XCTAssertThrowsError(try BrowserAddress.resolve(invalid), invalid)
        }
    }

    func testBrowserToolsParticipateInAgentLoopAndRequireApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints"))
        let browser = FixtureBrowser(), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        let model = BrowserScriptedModel([
            ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "nav", name: "browser_navigate", arguments: #"{"url":"http://localhost:3000"}"#)]),
            ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "type", name: "browser_type", arguments: #"{"snapshot":"fixture","reference":1,"text":"Hello"}"#)]),
            ModelMessage(role: "assistant", toolCalls: [ToolCall(id: "click", name: "browser_click", arguments: #"{"snapshot":"fixture","reference":2}"#)]),
            ModelMessage(role: "assistant", text: "Finished")
        ])
        var approvals: [String] = []
        harness.onEvent = { event in
            guard case .approval(let request?) = event else { return }
            approvals.append(request.detail)
            request.resolve(request.title == "Type in browser?")
        }
        let config = ModelConfiguration(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: "")
        let result = try await harness.run(configuration: config, messages: [], files: files, project: root.path, transport: model, browser: browser)
        XCTAssertEqual(browser.actions, ["navigate", "type:Hello"])
        XCTAssertEqual(approvals.count, 2)
        XCTAssertTrue(approvals.allSatisfy { $0.contains(browser.currentURL) && $0.contains("Message field") })
        XCTAssertTrue(result.contains { $0.toolCallID == "type" && $0.text == "Typed snapshot" })
        XCTAssertTrue(result.contains { $0.toolCallID == "click" && $0.text.contains("declined") })
        let names = await model.tools
        XCTAssertTrue(Set(BrowserTools.definitions.map(\.name)).isSubset(of: names))
    }

    func testNativeBrowserSnapshotsInteractionsAndStaleReferences() async throws {
        _ = NSApplication.shared
        let browser = BrowserSession()
        XCTAssertFalse(browser.hasCreatedWebView)
        defer { browser.close() }
        let view = browser.webView
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        view.setFrameSize(NSSize(width: 700, height: 500))
        view.loadHTMLString("""
        <!doctype html><html><head><title>Browser fixture</title></head><body>
        <h1>Local preview</h1><input placeholder="Message"><input type="password" aria-label="Password" value="never-read-this">
        <button onclick="document.getElementById('result').innerText='Applied: '+document.querySelector('input').value">Apply</button>
        <p id="result">Ready</p><div style="height:2000px"></div><p>Bottom</p></body></html>
        """, baseURL: URL(string: "https://browser.test")!)
        func snapshot(_ result: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        }
        let initialText = try await browser.readPage()
        let initial = try snapshot(initialText), id = try XCTUnwrap(initial["snapshot"] as? String)
        XCTAssertTrue(initialText.contains("Local preview"))
        XCTAssertFalse(initialText.contains("never-read-this"))
        let controls = try XCTUnwrap(initial["controls"] as? [[String: Any]])
        let input = try XCTUnwrap(controls.first { $0["label"] as? String == "Message" }?["reference"] as? Int)
        let password = try XCTUnwrap(controls.first { $0["type"] as? String == "password" }?["reference"] as? Int)
        do { _ = try await browser.targetDescription(snapshot: id, reference: password, typing: true); XCTFail("Password typing must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("credentials")) }
        let typed = try snapshot(await browser.type(snapshot: id, reference: input, text: "Hello from Bob"))
        do { _ = try await browser.click(snapshot: id, reference: input); XCTFail("An old snapshot must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Stale")) }
        let latest = try XCTUnwrap(typed["snapshot"] as? String)
        let nextControls = try XCTUnwrap(typed["controls"] as? [[String: Any]])
        let button = try XCTUnwrap(nextControls.first { $0["label"] as? String == "Apply" }?["reference"] as? Int)
        let clicked = try await browser.click(snapshot: latest, reference: button)
        XCTAssertTrue(clicked.contains("Applied: Hello from Bob"))
        _ = try await browser.scrollPage(direction: "down")
        XCTAssertTrue(view === browser.webView)
    }

    func testProjectBrowserIsLazyAndSurvivesPanelAndChatSwitches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { store.shutdown() }
        XCTAssertFalse(store.browser.hasCreatedWebView)
        store.browser.address = "http://localhost:3000"
        store.openPanel(.browser)
        store.openPanel(.editor)
        store.newSession()
        store.openPanel(.browser)
        XCTAssertEqual(store.browser.address, "http://localhost:3000")
        XCTAssertEqual(store.selectedPanel, .browser)
        XCTAssertTrue(store.showWorkspacePanel)
        XCTAssertFalse(store.browser.hasCreatedWebView)
    }
}
