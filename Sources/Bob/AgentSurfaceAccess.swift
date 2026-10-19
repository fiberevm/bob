import Foundation
import BobCore

/// Chats run independently, while each shared interactive surface has one owner
/// until its run ends. This keeps observations and cancellation in the same run.
@MainActor final class AgentSurfaceCoordinator {
    enum Surface: String { case browser = "Browser", computer = "Computer" }
    private(set) var owners: [Surface: UUID] = [:]
    func claim(_ surface: Surface, runID: UUID) throws {
        guard owners[surface] == nil || owners[surface] == runID else {
            throw BobError.message("Another chat is using the \(surface.rawValue) panel. Continue other work, or retry after that run finishes.")
        }
        owners[surface] = runID
    }
    func release(runID: UUID) { owners = owners.filter { $0.value != runID } }
}

@MainActor final class AgentSurfaceAccess {
    let runID: UUID
    private let coordinator: AgentSurfaceCoordinator
    private let tabKind: (UUID) -> WorkspacePanelKind?
    init(runID: UUID, coordinator: AgentSurfaceCoordinator, tabKind: @escaping (UUID) -> WorkspacePanelKind? = { _ in nil }) {
        self.runID = runID; self.coordinator = coordinator; self.tabKind = tabKind
    }
    func owns(_ surface: AgentSurfaceCoordinator.Surface) -> Bool { coordinator.owners[surface] == runID }
    func claim(for call: ToolCall) throws {
        let surface: AgentSurfaceCoordinator.Surface?
        if call.name.hasPrefix("browser_") { surface = .browser }
        else if call.name.hasPrefix("computer_") { surface = .computer }
        else {
            let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
            let kind: WorkspacePanelKind?
            if call.name == "workspace_open_tab", let value = args["kind"] as? String {
                kind = WorkspacePanelKind.allCases.first { $0.toolValue == value }
            } else if call.name == "workspace_close_tab", let value = args["tab_id"] as? String, let id = UUID(uuidString: value) {
                kind = tabKind(id)
            } else { kind = nil }
            surface = kind == .browser ? .browser : kind == .computer ? .computer : nil
        }
        if let surface { try coordinator.claim(surface, runID: runID) }
    }
    func cancel(browser: (any AgentBrowser)?, computer: (any AgentComputer)?) {
        if owns(.browser) { browser?.cancelAgentOperation() }
        if owns(.computer) { computer?.cancel() }
    }
    func release() { coordinator.release(runID: runID) }
}
