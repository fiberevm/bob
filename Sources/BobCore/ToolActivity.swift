import Foundation

public struct ToolActivity: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case running, completed, failed, declined, cancelled

        public var label: String { self == .failed ? "attempted" : rawValue }
    }
    public var id: String { call.id }
    public let call: ToolCall
    public var status: Status = .running
    public var output = ""
    public let startedAt: Date
    public var finishedAt: Date?
    public var review: ToolSafetyAssessment?
    public var reviewing: Bool?
    public var parentCallID: String?
    public var executionStarted: Bool?

    public init(call: ToolCall, startedAt: Date = Date(), parentCallID: String? = nil) {
        self.call = call; self.startedAt = startedAt; self.parentCallID = parentCallID
    }
    public mutating func finish(output: String, failed: Bool = false, cancelled: Bool = false) {
        reviewing = false
        self.output = output
        finishedAt = Date()
        if cancelled { status = .cancelled }
        else if output.hasPrefix("The user declined") { status = .declined }
        else if failed || (call.name == "run_command" && output.hasPrefix("Exit: ") && !output.hasPrefix("Exit: 0\n")) { status = .failed }
        else if call.name == "browser_delegate",
                let result = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
                let outcome = result["status"] as? String, ["blocked", "declined"].contains(outcome) {
            status = outcome == "blocked" ? .failed : .declined
        }
        else { status = .completed }
    }
    public var title: String {
        let verbs: (running: String, completed: String)
        switch call.name {
        case "list_files": verbs = ("Exploring", "Explored")
        case "read_file": verbs = ("Reading", "Read")
        case "write_file": verbs = ("Editing", "Edited")
        case "run_command": verbs = ("Running", "Ran")
        case "browser_navigate": verbs = ("Opening", "Opened")
        case "browser_delegate": verbs = ("Navigating with Clef", "Navigated with Clef")
        case "browser_read": verbs = ("Reading page", "Read page")
        case "browser_click": verbs = ("Clicking", "Clicked")
        case "browser_type": verbs = ("Typing", "Typed")
        case "browser_scroll": verbs = ("Scrolling", "Scrolled")
        case "computer_apps": verbs = ("Finding apps", "Listed apps")
        case "computer_open": verbs = ("Opening app", "Opened app")
        case "computer_snapshot": verbs = ("Capturing window", "Captured window")
        case "computer_action": verbs = ("Using computer", "Used computer")
        case "workspace_tabs": verbs = ("Checking tabs", "Checked tabs")
        case "workspace_open_tab": verbs = ("Opening tab", "Opened tab")
        case "workspace_select_tab": verbs = ("Selecting tab", "Selected tab")
        case "workspace_close_tab": verbs = ("Closing tab", "Closed tab")
        case "workspace_read_plan": verbs = ("Reading plan", "Read plan")
        case "workspace_update_plan": verbs = ("Updating plan", "Updated plan")
        default:
            let name = call.name.replacingOccurrences(of: "_", with: " ")
            verbs = (name, name)
        }
        let verb = status == .running ? verbs.running : verbs.completed
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        let value = ["command", "path", "url", "app", "kind"].compactMap { args[$0] as? String }.first ?? ""
        let detail = call.name == "list_files" && value.isEmpty ? "project" : value
        let prefix: String
        switch status {
        case .failed:
            let attempt = verbs.running.prefix(1).lowercased() + verbs.running.dropFirst()
            return "Tried " + attempt + (detail.isEmpty ? "" : " \(detail)")
        case .declined: prefix = "Declined · "
        case .cancelled: prefix = "Stopped · "
        default: prefix = ""
        }
        return prefix + verb + (detail.isEmpty ? "" : " \(detail)")
    }
}
