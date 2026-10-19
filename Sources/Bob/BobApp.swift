import SwiftUI
import AppKit

private struct WorkspaceStoreKey: FocusedValueKey { typealias Value = AppStore }
extension FocusedValues {
    var workspaceStore: AppStore? {
        get { self[WorkspaceStoreKey.self] }
        set { self[WorkspaceStoreKey.self] = newValue }
    }
}

@main struct BobApp: App {
    @FocusedValue(\.workspaceStore) private var store
    @Environment(\.openWindow) private var openWindow
    private static var initialProject: String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--project"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1]).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return UserDefaults.standard.string(forKey: "projects.last") ?? ""
    }
    var body: some Scene {
        WindowGroup("Bob", id: "project", for: String.self) { $project in
            ProjectWindow(projectPath: project)
        } defaultValue: { Self.initialProject }
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store?.newSession() }.keyboardShortcut("n").disabled(store?.selected == nil)
                Button("Open Project…") { store?.openProject() }.keyboardShortcut("o")
                Button("Project Launcher") { openWindow(id: "project", value: "") }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store?.showSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(after: .saveItem) {
                Button("Save File") { store?.saveFile() }.keyboardShortcut("s").disabled(store?.editorDirty != true)
                Button("Close Tab") { store?.closeSelectedTab() }.keyboardShortcut("w").disabled(store?.showWorkspacePanel != true || store?.canCloseSelectedTab != true)
            }
            CommandMenu("Workspace") {
                Button("Command Center…") { store?.openCommandPalette() }.keyboardShortcut("k")
                Button("Find File…") { store?.openCommandPalette(scope: .files) }.keyboardShortcut("p")
                Button("Show Terminal") { store?.startTerminal() }.keyboardShortcut("j")
                Button("Show Editor") { store?.openPanel(.editor) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Show Changes") { store?.openPanel(.changes) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Show Browser") { store?.openPanel(.browser) }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Show Computer") { store?.openPanel(.computer) }.keyboardShortcut("4", modifiers: [.command, .option])
                Button("Show Simulator") { store?.openPanel(.simulator) }.keyboardShortcut("5", modifiers: [.command, .option])
                Button("Show Plan") { store?.openPanel(.plan) }.keyboardShortcut("6", modifiers: [.command, .option])
                Divider()
                Button("Stop Agent") { store?.stop() }.keyboardShortcut(".").disabled(store?.isRunning != true)
                Button("Review Changes") { store?.reviewChanges() }
                Button("Undo Last Bob File Edit") { store?.undoFile() }.disabled(store?.checkpoints.isEmpty != false)
            }
        }
    }
}

private struct ProjectWindow: View {
    @StateObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    init(projectPath: String) { _store = StateObject(wrappedValue: AppStore(projectPath: projectPath)) }
    var body: some View {
        WorkspaceView(store: store)
            .frame(minWidth: 1080, minHeight: 700)
            .focusedSceneValue(\.workspaceStore, store)
            .onAppear {
                let open = openWindow, close = dismiss
                store.onOpenProject = { [weak store] path in
                    open(id: "project", value: path)
                    if store?.boundProjectPath.isEmpty == true { close() }
                }
            }
            .onDisappear { store.shutdown() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.shutdown() }
    }
}
