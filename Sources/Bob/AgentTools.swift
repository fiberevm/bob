import Foundation
import BobCore

@MainActor final class AgentTools {
    private let files: WorkspaceFiles
    private let project: String
    private let browser: (any AgentBrowser)?
    private let computer: (any AgentComputer)?
    private let workspace: (any AgentWorkspace)?
    private let workspaceSessionID: UUID?
    private let decisions: LocalDecisionModel?
    private let reviewer: any ToolSafetyReviewing
    private let navigationModel: (any DecisionEvaluating)?
    private let onDelegatedTool: (ToolActivity) async throws -> Void
    private var delegationHistory: [String: [ModelMessage]] = [:]
    private let trustedUserMessages: [String]
    private let input: AgentInput
    private var reviews: [String: (ToolCall, ToolSafetyAssessment)] = [:]
    private var allowedComputerApps = Set<String>()
    private var accessRevision = -1
    private let approvals: ApprovalCoordinator
    private let policy = PermissionPolicy()
    private let rootInstructions: String
    private let surfaces: AgentSurfaceAccess?
    private var delivered: Set<String>
    private var staged = Set<String>()
    init(files: WorkspaceFiles, project: String, browser: (any AgentBrowser)?, computer: (any AgentComputer)? = nil, workspace: (any AgentWorkspace)? = nil, workspaceSessionID: UUID? = nil, decisions: LocalDecisionModel? = LocalDecisions.model, reviewer: (any ToolSafetyReviewing)? = nil, navigationModel: (any DecisionEvaluating)? = nil, onDelegatedTool: @escaping (ToolActivity) async throws -> Void = { _ in }, trustedUserMessages: [String] = [], approvals: ApprovalCoordinator, rootInstructions: String, surfaces: AgentSurfaceAccess? = nil, input: AgentInput = AgentInput()) {
        self.files = files; self.project = project; self.browser = browser; self.computer = computer; self.workspace = workspace; self.approvals = approvals
        self.workspaceSessionID = workspaceSessionID
        self.rootInstructions = rootInstructions
        self.surfaces = surfaces
        self.decisions = decisions
        self.reviewer = reviewer ?? ClefToolSafetyReviewer(model: decisions)
        self.navigationModel = navigationModel ?? decisions
        self.onDelegatedTool = onDelegatedTool
        self.trustedUserMessages = trustedUserMessages
        self.input = input
        delivered = [rootInstructions, ""]
    }
    var registry: ToolRegistry {
        let definitions = WorkspaceTools.definitions + (browser == nil ? [] : BrowserTools.definitions) + (computer == nil ? [] : ComputerTools.definitions) + (workspace == nil ? [] : WorkspaceTabTools.definitions) + (decisions == nil ? [] : LocalDecisions.definitions)
        return ToolRegistry(definitions: definitions, beforeSampling: { await self.didDeliverInstructions() }, afterCompaction: { await self.resetInstructions() }, review: { call, history in
            guard let definition = definitions.first(where: { $0.name == call.name }) else { throw BobError.message("Unknown tool.") }
            return try await self.review(call, definition: definition, history: history)
        }, perform: { @MainActor call in
            try await self.performReviewed(call)
        })
    }
    private func performReviewed(_ call: ToolCall) async throws -> ToolResult {
        defer { reviews[call.id] = nil; delegationHistory[call.id] = nil }
        try input.checkPending()
        // These tools already ask at the exact side-effect boundary. Other
        // tools acquire a confirmation here when risk is high or critical.
        if !["write_file", "run_command", "browser_click", "browser_type", "computer_open", "computer_snapshot", "computer_action"].contains(call.name),
           assessment(for: call)?.outcome == .needsApproval {
            guard try await authorize(.read, call: call, title: "Review \(call.name)?", detail: "Tool: \(call.name)\nExact arguments:\n\(call.arguments)") else {
                return ToolResult(text: "The user declined this tool call after Clef review.")
            }
        }
        if call.name.hasPrefix("computer_") { return try await computerTool(call) }
        return ToolResult(text: try await execute(call))
    }
    private func assessment(for call: ToolCall) -> ToolSafetyAssessment? {
        guard let (reviewed, assessment) = reviews[call.id], reviewed == call else { return nil }
        return assessment
    }
    private func review(_ call: ToolCall, definition: ToolDefinition, history: [ModelMessage]) async throws -> ToolSafetyAssessment {
        try Task.checkCancellation()
        try surfaces?.claim(for: call)
        var target = ""
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        if call.name == "computer_action", let computer {
            let action = try ComputerAction(arguments: args), snapshot = try computer.current(action.snapshot)
            try action.validate(in: snapshot)
            target = "App: \(snapshot.app.bundleID)\nWindow: \(snapshot.windowID) \(snapshot.title)\nAction: \(action.description(in: snapshot))"
        } else if ["browser_click", "browser_type"].contains(call.name), let browser,
                  let snapshot = args["snapshot"] as? String, let reference = args["reference"] as? Int {
            target = "Page: \(browser.currentURL)\nControl: " + (try await browser.targetDescription(snapshot: snapshot, reference: reference, typing: call.name == "browser_type"))
        } else if call.name == "browser_navigate", let browser, let url = args["url"] as? String {
            target = "Current page: \(browser.currentURL)\nDestination: \(url)"
            if let page = history.reversed().filter({ $0.role == "tool" }).compactMap({ try? BrowserNavigationPage.parse($0.text) }).first,
               page.url == browser.currentURL, let link = page.controls.first(where: { $0.href == url }) {
                target += "\nObserved link: \(link.label) → \(url)"
            }
        }
        let evidence = history.suffix(8).filter { $0.role != "user" }.map { message in
            let content = message.text + message.toolCalls.map { "\nPlanned \($0.name): \($0.arguments)" }.joined()
            return "\(message.role): " + String(content.prefix(8000)) + (content.count > 8000 ? "\n<truncated evidence; do not assume omitted content is benign>" : "")
        }
        let context = ToolReviewContext(project: project, userMessages: trustedUserMessages + input.userMessages, evidence: evidence, target: target)
        let reviewer = self.reviewer
        let assessment = try await input.interruptible {
            try await reviewer.review(call, definition: definition, context: context)
        }
        try Task.checkCancellation()
        reviews[call.id] = (call, assessment)
        if call.name == "browser_delegate" { delegationHistory[call.id] = history }
        return assessment
    }
    private func delegateBrowser(_ call: ToolCall) async throws -> String {
        guard browser != nil, let navigationModel else { throw BobError.message("Local browser navigation requires the Clef runtime. Run make decisions and rebuild Bob.") }
        let task = try JSONDecoder().decode(BrowserNavigationTask.self, from: Data(call.arguments.utf8))
        var history = delegationHistory[call.id] ?? []
        let report = try await ClefBrowserNavigator(model: navigationModel).run(task: task) { step in
            let result = try await self.performDelegated(step, parent: call.id, history: history)
            history.append(.init(role: "assistant", toolCalls: [step]))
            history.append(.init(role: "tool", text: result, toolCallID: step.id))
            return result
        }
        return try report.toolOutput()
    }
    private func performDelegated(_ call: ToolCall, parent: String, history: [ModelMessage]) async throws -> String {
        guard ["browser_navigate", "browser_read", "browser_click", "browser_type", "browser_scroll"].contains(call.name) else {
            throw BobError.message("Clef proposed an unsupported browser action.")
        }
        var activity = ToolActivity(call: call, parentCallID: parent)
        activity.reviewing = true
        try await onDelegatedTool(activity)
        do {
            let result = try await registry.perform(call, history: history, onReview: { assessment in
                activity.review = assessment; activity.reviewing = false
                try await self.onDelegatedTool(activity)
            }, beforeExecution: {
                activity.executionStarted = true
                try await self.onDelegatedTool(activity)
            })
            activity.finish(output: String(result.text.prefix(8000)))
            try await onDelegatedTool(activity)
            return result.text
        } catch {
            activity.finish(output: error.localizedDescription, failed: !(error is CancellationError), cancelled: error is CancellationError)
            try await onDelegatedTool(activity)
            throw error
        }
    }
    private func allowApp(_ id: String, call: ToolCall, computer: any AgentComputer) async throws -> Bool {
        try input.checkPending()
        guard computer.enabled else { throw BobError.message("Enable computer use in the Computer panel first.") }
        let app = try computer.application(id)
        if accessRevision != computer.permissionRevision { allowedComputerApps = []; accessRevision = computer.permissionRevision }
        let review = assessment(for: call)
        let needsConfirmation = ["computer_open", "computer_snapshot"].contains(call.name) && review?.outcome == .needsApproval
        if (allowedComputerApps.contains(id) || computer.isAlwaysAllowed(id)) && !needsConfirmation { return true }
        if let review = assessment(for: call), !policy.requiresApproval(.computerInteraction, assessment: review) {
            allowedComputerApps.insert(id)
            return true
        }
        let summary = review.map { $0.summary + "\n\n" } ?? ""
        let approved = await approvals.request(callID: call.id, title: "Use \(app.name)?", detail: summary + "App: \(app.name) (\(id))\nTool: \(call.name)\nExact arguments:\n\(call.arguments)\n\nAllow Bob to open this app, capture its windows, and send screenshots and accessibility text to the selected model. High- and critical-risk actions require confirmation. Allow once grants app access for this run.", remember: { computer.remember(id) })
        try Task.checkCancellation()
        try input.checkPending()
        if approved { accessRevision = computer.permissionRevision; allowedComputerApps.insert(id) }
        return approved
    }
    private func computerTool(_ call: ToolCall) async throws -> ToolResult {
        guard let computer else { throw BobError.message("Computer use is unavailable.") }
        guard let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any] else { throw BobError.message("Invalid computer tool arguments.") }
        if call.name == "computer_apps" { return ToolResult(text: computer.appsDescription()) }
        if call.name == "computer_action" {
            let action = try ComputerAction(arguments: args), state = try computer.current(action.snapshot)
            try action.validate(in: state)
            guard try await allowApp(state.app.bundleID, call: call, computer: computer) else { return ToolResult(text: "The user declined app access.") }
            guard try await authorize(.computerInteraction, call: call, title: "Use \(state.app.name)?", detail: "Window: \(state.title)\n\n\(action.description(in: state))\n\nCoordinate and keyboard actions may bring this app forward. Desktop changes are not covered by file checkpoints.") else { return ToolResult(text: "The user declined this desktop action.") }
            return try await computer.perform(action)
        }
        guard let id = args["app"] as? String, !id.isEmpty else { throw BobError.message("Specify an app bundle ID from computer_apps.") }
        guard try await allowApp(id, call: call, computer: computer) else { return ToolResult(text: "The user declined app access.") }
        switch call.name {
        case "computer_open": return try await computer.open(id)
        case "computer_snapshot":
            if let value = args["window_id"], !(value is UInt32) { throw BobError.message("window_id must be a valid window number.") }
            return try await computer.capture(id, windowID: args["window_id"] as? UInt32).result
        default: throw BobError.message("Unknown computer tool.")
        }
    }
    private func didDeliverInstructions() { delivered.formUnion(staged); staged = [] }
    private func resetInstructions() {
        delivered = [rootInstructions, ""]; staged = []
        if surfaces == nil || surfaces?.owns(.computer) == true { computer?.cancel() }
    }
    private func instructions(_ path: String) async throws -> String {
        let content = try await ProjectInstructions.load(files: files, path: path)
        guard !delivered.contains(content) else { return "" }
        staged.insert(content)
        return content
    }
    private func authorize(_ effect: ToolEffect, call: ToolCall, title: String, detail: String) async throws -> Bool {
        try Task.checkCancellation()
        try input.checkPending()
        let accepted: Bool
        let review = assessment(for: call)
        if policy.requiresApproval(effect, assessment: review) || review?.outcome == .needsApproval {
            let summary = review.map { $0.summary + "\n\n" } ?? ""
            accepted = await approvals.request(callID: call.id, title: title, detail: summary + detail)
        }
        else { accepted = true }
        try Task.checkCancellation()
        try input.checkPending()
        return accepted
    }
    private func execute(_ call: ToolCall) async throws -> String {
        if call.name == "browser_delegate" { return try await delegateBrowser(call) }
        if call.name == "local_decide" {
            guard let decisions else { throw BobError.message("Set up Clef-flash with make decisions first.") }
            let request = try JSONDecoder().decode(DecisionRequest.self, from: Data(call.arguments.utf8))
            let response = try await decisions.decide(request)
            return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        }
        guard let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any] else { throw BobError.message("Invalid tool arguments.") }
        func argument(_ key: String) throws -> String {
            guard let value = args[key] as? String else { throw BobError.message("Missing tool argument: \(key)") }; return value
        }
        if call.name.hasPrefix("workspace_") {
            try Task.checkCancellation()
            guard let workspace else { throw BobError.message("Workspace tabs are unavailable in this run.") }
            switch call.name {
            case "workspace_tabs": return try workspace.tabsDescription()
            case "workspace_read_plan": return try workspace.readWorkspacePlan(sessionID: workspaceSessionID)
            case "workspace_update_plan": return try workspace.updateWorkspacePlan(argument("markdown"), sessionID: workspaceSessionID)
            case "workspace_open_tab":
                let value = try argument("kind")
                guard let kind = WorkspacePanelKind.allCases.first(where: { $0.toolValue == value }) else { throw BobError.message("Unknown workspace tab kind.") }
                for key in ["path", "url"] where args[key] != nil {
                    guard args[key] is String else { throw BobError.message("\(key) must be a string.") }
                }
                return try await workspace.openWorkspaceTab(kind: kind, path: args["path"] as? String, url: args["url"] as? String)
            case "workspace_select_tab", "workspace_close_tab":
                guard let id = UUID(uuidString: try argument("tab_id")) else { throw BobError.message("Use an exact tab_id from workspace_tabs.") }
                return call.name == "workspace_select_tab" ? try workspace.selectWorkspaceTab(id) : try workspace.closeWorkspaceTab(id)
            default: throw BobError.message("Unknown workspace tool: \(call.name)")
            }
        }
        if call.name.hasPrefix("browser_") {
            guard let browser else { throw BobError.message("The browser is unavailable in this run.") }
            switch call.name {
            case "browser_navigate": return try await browser.navigate(argument("url"))
            case "browser_read": return try await browser.readPage()
            case "browser_scroll": return try await browser.scrollPage(direction: argument("direction"))
            case "browser_click", "browser_type":
                let snapshot = try argument("snapshot")
                guard let reference = args["reference"] as? Int, reference > 0 else { throw BobError.message("Use a control reference from the latest browser snapshot.") }
                let typing = call.name == "browser_type", text = typing ? try argument("text") : ""
                let target = try await browser.targetDescription(snapshot: snapshot, reference: reference, typing: typing)
                let detail = "Page: \(browser.currentURL)\nControl: \(target)" + (typing ? "\n\nReplace field content with:\n\(text)" : "")
                guard try await authorize(.browserInteraction, call: call, title: typing ? "Type in browser?" : "Click browser control?", detail: detail) else { return "The user declined this browser interaction." }
                if typing { return try await browser.type(snapshot: snapshot, reference: reference, text: text) }
                return try await browser.click(snapshot: snapshot, reference: reference)
            default: throw BobError.message("Unknown browser tool: \(call.name)")
            }
        }
        switch call.name {
        case "list_files":
            let path = try argument("path"), docs = try await instructions(path)
            let listing = try await files.list(path).map { "\($0.isDirectory ? "directory" : "file") \($0.name)" }.joined(separator: "\n")
            return docs.isEmpty ? listing : docs + "\n\n" + listing
        case "read_file":
            let path = try argument("path"), docs = try await instructions(path)
            let text = try await files.read(path)
            return docs.isEmpty ? text : docs + "\n\n" + text
        case "write_file":
            let path = try argument("path"), content = try argument("content"), docs = try await instructions(path)
            guard docs.isEmpty else { return "Read these applicable instructions, then reissue the write in your next response:\n" + docs }
            let previous = try await files.expectation(path)
            guard try await authorize(.write, call: call, title: "Write \(URL(fileURLWithPath: path).lastPathComponent)?", detail: "Project: \(project)\nFile: \(path)\n\nProposed content (\(content.utf8.count) bytes):\n\(content)") else { return "The user declined this file write." }
            try await files.write(path, text: content, expectation: previous)
            return "Saved \(path). An undo checkpoint was created."
        case "run_command":
            let command = try argument("command")
            guard try await authorize(.shell, call: call, title: "Run shell command?", detail: "Directory: \(project)\n\n\(command)\n\nRuns directly on this Mac with your user account's file and network access. Shell changes are not covered by file checkpoints.") else { return "The user declined this command." }
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-c", command], directory: URL(fileURLWithPath: project), timeout: 60, environment: policy.shellEnvironment())
            try Task.checkCancellation()
            return "Exit: \(result.status)\n\(result.output)\n\(result.error)"
        default: throw BobError.message("Unknown tool: \(call.name)")
        }
    }
}
