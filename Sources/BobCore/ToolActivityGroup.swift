import Foundation

public struct ToolActivityGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tools: [ToolActivity]
    public init(id: UUID, tools: [ToolActivity]) { self.id = id; self.tools = tools }

    public var activeTool: ToolActivity? { tools.last { $0.status == .running } }
    public var status: ToolActivity.Status {
        if activeTool != nil { return .running }
        if tools.contains(where: { $0.status == .failed }) { return .failed }
        if tools.contains(where: { $0.status == .cancelled }) { return .cancelled }
        if tools.contains(where: { $0.status == .declined }) { return .declined }
        return .completed
    }
    public var notices: String {
        [(ToolActivity.Status.declined, "declined"), (.cancelled, "stopped")].compactMap { status, label in
            let count = tools.filter { $0.status == status }.count
            return count == 0 ? nil : "\(count) \(label)"
        }.joined(separator: " · ")
    }
    public var duration: TimeInterval? {
        guard activeTool == nil, let start = tools.map(\.startedAt).min(),
              tools.allSatisfy({ $0.finishedAt != nil }), let end = tools.compactMap(\.finishedAt).max() else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
    public var title: String {
        if tools.count == 1 { return tools[0].title }
        let running = activeTool != nil
        if tools.allSatisfy({ ["read_file", "list_files"].contains($0.call.name) }) {
            let reads = fileCount(for: "read_file")
            let lists = tools.filter { $0.call.name == "list_files" }.count
            let detail = [(reads, "file", "files"), (lists, "list", "lists")].compactMap { count, singular, plural in
                count == 0 ? nil : "\(count) \(count == 1 ? singular : plural)"
            }.joined(separator: ", ")
            return "\(running ? "Exploring" : "Explored") \(detail)"
        }
        if tools.allSatisfy({ $0.call.name == "write_file" }) {
            let count = fileCount(for: "write_file")
            return "\(running ? "Editing" : "Edited") \(count) \(count == 1 ? "file" : "files")"
        }
        if tools.allSatisfy({ $0.call.name == "run_command" }) { return "\(running ? "Running" : "Ran") \(tools.count) commands" }
        if tools.allSatisfy({ $0.call.name.hasPrefix("browser_") }) { return "\(running ? "Using browser" : "Used browser") · \(tools.count) actions" }
        if tools.allSatisfy({ $0.call.name.hasPrefix("computer_") }) { return "\(running ? "Using computer" : "Used computer") · \(tools.count) actions" }
        return "\(running ? "Using" : "Used") \(tools.count) tools"
    }
    private func fileCount(for name: String) -> Int {
        Set(tools.filter { $0.call.name == name }.map { tool in
            let args = (try? JSONSerialization.jsonObject(with: Data(tool.call.arguments.utf8))) as? [String: Any]
            return args?["path"] as? String ?? tool.id
        }).count
    }
}
