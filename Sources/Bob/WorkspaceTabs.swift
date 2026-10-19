import Foundation
import BobCore

enum WorkspacePanelKind: String, CaseIterable {
    case editor = "Editor", plan = "Plan", changes = "Changes", terminal = "Terminal", browser = "Browser", computer = "Computer", simulator = "Simulator"

    var toolValue: String { rawValue.lowercased() }
    var symbol: String {
        switch self {
        case .editor: return "doc.text"
        case .plan: return "list.bullet.rectangle"
        case .changes: return "arrow.triangle.branch"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .computer: return "desktopcomputer"
        case .simulator: return "iphone"
        }
    }
}

struct WorkspaceTab: Identifiable, Equatable {
    let id: UUID
    let kind: WorkspacePanelKind
    init(_ kind: WorkspacePanelKind) { id = UUID(); self.kind = kind }
}

struct EditorBuffer {
    var path: String?
    var text = ""
    var original = ""
    var isDirty: Bool { text != original }
}

@MainActor protocol AgentWorkspace: AnyObject {
    func tabsDescription() throws -> String
    func openWorkspaceTab(kind: WorkspacePanelKind, path: String?, url: String?) async throws -> String
    func selectWorkspaceTab(_ id: UUID) throws -> String
    func closeWorkspaceTab(_ id: UUID) throws -> String
    func readWorkspacePlan(sessionID: UUID?) throws -> String
    func updateWorkspacePlan(_ markdown: String, sessionID: UUID?) throws -> String
}

enum WorkspaceTabTools {
    static var definitions: [ToolDefinition] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> ToolDefinition {
            ToolDefinition(name: name, description: description, parameters: ["type": "object", "properties": properties, "required": required, "additionalProperties": false])
        }
        let id: [String: Any] = ["tab_id": ["type": "string", "description": "Exact tab ID returned by workspace_tabs or workspace_open_tab."]]
        return [
            tool("workspace_tabs", "List this project's open workspace tabs, their IDs, active selection, and unsaved state. The agent conversation always stays visible.", [:], []),
            tool("workspace_open_tab", "Open and select a workspace tab. An editor path selects its existing tab if already open; otherwise it replaces the current clean editor tab or opens a new tab to preserve unsaved edits. Plan displays this chat's saved Markdown plan; use workspace_update_plan to write it. Plan, browser, terminal, changes, computer, and simulator tabs are reused. Optional url navigates the built-in browser. Opening Computer does not grant desktop access. Opening Simulator does not boot a device or grant agent input access. Use this to show relevant work to the user.", [
                "kind": ["type": "string", "enum": WorkspacePanelKind.allCases.map(\.toolValue)],
                "path": ["type": "string", "description": "Optional project-relative file path. Only valid for editor."],
                "url": ["type": "string", "description": "Optional HTTP/HTTPS address. Only valid for browser."]
            ], ["kind"]),
            tool("workspace_select_tab", "Select an existing workspace tab by ID. This preserves each file's unsaved buffer.", id, ["tab_id"]),
            tool("workspace_close_tab", "Close an existing file or workspace tab. Closing the last file leaves an empty Editor tab open. The empty Editor tab stays open. Closing Plan preserves its saved content. Unsaved file tabs and running terminals cannot be closed by the agent.", id, ["tab_id"]),
            tool("workspace_read_plan", "Read the saved Markdown plan for this agent's chat. This does not change the selected chat or tab.", [:], []),
            tool("workspace_update_plan", "Create or replace this agent's chat plan with detailed Markdown, including goals, steps, checklists, risks, and validation when useful. Saves the plan across restarts and opens Plan if this chat is selected. Other chats' plans are preserved. Markdown is displayed as text; it does not run commands or change project files. Maximum 200,000 UTF-8 bytes.", [
                "markdown": ["type": "string", "description": "The complete Markdown plan. Read the existing plan before revising it; retain relevant detail and progress. An empty string clears it."]
            ], ["markdown"])
        ]
    }
}

extension AppStore: AgentWorkspace {
    func tabsDescription() throws -> String {
        let tabs: [[String: Any]] = openTabs.map { tab in
            var item: [String: Any] = ["tab_id": tab.id.uuidString, "kind": tab.kind.toolValue,
                "title": tabTitle(tab), "selected": selectedTabID == tab.id, "unsaved": tabIsDirty(tab)]
            if tab.kind == .editor, let path = buffer(for: tab.id)?.path { item["path"] = path }
            if tab.kind == .browser { item["url"] = browser.currentURL }
            return item
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["visible": showWorkspacePanel, "tabs": tabs], options: [.sortedKeys]), as: UTF8.self)
    }

    func openWorkspaceTab(kind: WorkspacePanelKind, path: String?, url: String?) async throws -> String {
        try Task.checkCancellation()
        guard path == nil || kind == .editor, url == nil || kind == .browser else {
            throw BobError.message("path is only valid for editor tabs; url is only valid for browser tabs.")
        }
        // Validate before opening a tab so an invalid request leaves the workspace alone.
        if let url { _ = try BrowserAddress.resolve(url) }
        if let path { _ = try await openFileTab(path) }
        else { openPanel(kind) }
        if let url { _ = try await browser.navigate(url) }
        return try tabsDescription()
    }

    func selectWorkspaceTab(_ id: UUID) throws -> String {
        guard openTabs.contains(where: { $0.id == id }) else { throw BobError.message("This tab is no longer open. Call workspace_tabs again.") }
        selectTab(id)
        return try tabsDescription()
    }

    func closeWorkspaceTab(_ id: UUID) throws -> String {
        try closeTab(id, fromAgent: true)
        return try tabsDescription()
    }
}
