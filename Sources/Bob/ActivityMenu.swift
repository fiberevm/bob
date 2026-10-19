import AppKit
import Combine
import SwiftUI

struct RunningChatActivity: Identifiable, Equatable {
    let id: UUID
    let title: String
    let activity: String
    let needsApproval: Bool
}

/// Tracks live windows, not the focused scene, so background projects remain visible.
@MainActor final class ActivityMenuStore: ObservableObject {
    private final class Workspace {
        weak var store: AppStore?
        weak var window: NSWindow?
        var observation: AnyCancellable?
        init(store: AppStore, window: NSWindow?) { self.store = store; self.window = window }
    }
    struct Item: Identifiable {
        let workspaceID: ObjectIdentifier
        let project: String
        let chat: RunningChatActivity
        var id: String { "\(workspaceID)-\(chat.id)" }
    }
    private var workspaces: [ObjectIdentifier: Workspace] = [:]

    var items: [Item] {
        workspaces.flatMap { id, workspace -> [Item] in
            guard let store = workspace.store else { return [] }
            let project = URL(fileURLWithPath: store.boundProjectPath).lastPathComponent
            return store.runningChatActivities.map { Item(workspaceID: id, project: project, chat: $0) }
        }.sorted {
            if $0.chat.needsApproval != $1.chat.needsApproval { return $0.chat.needsApproval }
            return ($0.project, $0.chat.title, $0.id) < ($1.project, $1.chat.title, $1.id)
        }
    }
    var approvalCount: Int { items.filter { $0.chat.needsApproval }.count }
    var symbol: String { approvalCount > 0 ? "exclamationmark.circle.fill" : items.isEmpty ? "circle" : "circle.dotted.circle.fill" }
    var summary: String {
        let count = items.count
        if approvalCount > 0 { return "Bob: \(approvalCount) awaiting approval · \(count) active" }
        return count == 0 ? "Bob: Ready" : "Bob: \(count) active \(count == 1 ? "chat" : "chats")"
    }

    func register(_ store: AppStore, window: NSWindow?) {
        let id = ObjectIdentifier(store)
        if let existing = workspaces[id] { existing.window = window; return }
        let workspace = Workspace(store: store, window: window)
        workspace.observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        objectWillChange.send()
        workspaces[id] = workspace
    }
    func unregister(_ store: AppStore) {
        objectWillChange.send()
        workspaces[ObjectIdentifier(store)] = nil
    }
    func show(_ item: Item) {
        guard let workspace = workspaces[item.workspaceID], let store = workspace.store else { return }
        store.select(item.chat.id)
        workspace.window?.deminiaturize(nil)
        workspace.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ActivityMenu: View {
    @ObservedObject var activity: ActivityMenuStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(activity.summary)
        Divider()
        ForEach(activity.items) { item in
            Button { activity.show(item) } label: {
                Label("\(item.project) — \(item.chat.title): \(item.chat.needsApproval ? "Approval needed" : item.chat.activity)",
                      systemImage: item.chat.needsApproval ? "exclamationmark.circle.fill" : "circle.dotted.circle.fill")
            }
        }
        if !activity.items.isEmpty { Divider() }
        Button("Open Bob") {
            openWindow(id: "project", value: UserDefaults.standard.string(forKey: "projects.last") ?? "")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Project Launcher") {
            openWindow(id: "project", value: "")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Captures the actual owning window, including when several projects are open.
struct ActivityWindowRegistration: NSViewRepresentable {
    let store: AppStore
    let activity: ActivityMenuStore
    func makeNSView(context: Context) -> RegistrationView { RegistrationView() }
    func updateNSView(_ view: RegistrationView, context: Context) {
        view.register = { [weak store, weak activity] window in
            guard let store else { return }
            activity?.register(store, window: window)
        }
        if let window = view.window { view.register?(window) }
    }
    final class RegistrationView: NSView {
        var register: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register?(window) }
        }
    }
}
