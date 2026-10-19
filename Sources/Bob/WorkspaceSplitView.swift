import AppKit
import SwiftUI

struct WorkspaceSplitView: NSViewControllerRepresentable {
    @ObservedObject var store: AppStore

    func makeNSViewController(context: Context) -> WorkspaceSplitController {
        WorkspaceSplitController(store: store)
    }
    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {}
}

struct EditorSplitView: NSViewControllerRepresentable {
    @ObservedObject var store: AppStore

    func makeNSViewController(context: Context) -> EditorSplitController {
        EditorSplitController(store: store)
    }
    func updateNSViewController(_ controller: EditorSplitController, context: Context) {}
}

/// Set the file tree's initial width once, leaving subsequent sizing to the user's divider.
@MainActor final class EditorSplitController: NSSplitViewController {
    private let editorItem: NSSplitViewItem
    private var hasSetInitialFileTreeWidth = false

    init(store: AppStore) {
        let files = NSSplitViewItem(viewController: NSHostingController(rootView:
            FileBrowserView(store: store).frame(minWidth: 0, maxWidth: .infinity)))
        files.minimumThickness = 0
        files.maximumThickness = NSSplitViewItem.unspecifiedDimension
        files.holdingPriority = NSLayoutConstraint.Priority(252)
        editorItem = NSSplitViewItem(viewController: NSHostingController(rootView: EditorWithTerminalView(store: store)))
        editorItem.minimumThickness = 260
        editorItem.holdingPriority = NSLayoutConstraint.Priority(251)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(files)
        addSplitViewItem(editorItem)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let availableWidth = splitView.bounds.width - splitView.dividerThickness
        guard !hasSetInitialFileTreeWidth, availableWidth >= editorItem.minimumThickness else { return }
        hasSetInitialFileTreeWidth = true
        splitView.setPosition(min(200, availableWidth - editorItem.minimumThickness), ofDividerAt: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Keep chat and workspace visible together, with a resizable divider and chat capped at 800 points.
@MainActor final class WorkspaceSplitController: NSSplitViewController {
    let panelItem: NSSplitViewItem
    private var hasSetInitialChatWidth = false

    init(store: AppStore) {
        let chatController = NSHostingController(rootView: ChatView(store: store))
        chatController.safeAreaRegions = []
        let chat = NSSplitViewItem(viewController: chatController)
        chat.minimumThickness = 420
        chat.maximumThickness = 800
        chat.holdingPriority = NSLayoutConstraint.Priority(252)
        let panelController = NSHostingController(rootView: WorkspacePanel(store: store))
        panelController.safeAreaRegions = []
        panelItem = NSSplitViewItem(viewController: panelController)
        panelItem.minimumThickness = 420
        panelItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        panelItem.holdingPriority = NSLayoutConstraint.Priority(251)
        panelItem.canCollapse = false
        panelItem.canCollapseFromWindowResize = false
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(chat)
        addSplitViewItem(panelItem)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let availableWidth = splitView.bounds.width - splitView.dividerThickness
        guard !hasSetInitialChatWidth, availableWidth >= 840 else { return }
        hasSetInitialChatWidth = true
        splitView.setPosition(min(600, availableWidth - panelItem.minimumThickness), ofDividerAt: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The drawer belongs to the editor column, leaving the file tree full-height.
private struct EditorWithTerminalView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VSplitView {
            EditorView(store: store).frame(minHeight: 120)
            if store.showEditorTerminal {
                VStack(spacing: 0) {
                    HStack {
                        Label("Terminal", systemImage: "terminal")
                        Spacer()
                        Button { store.terminal.clear() } label: { Image(systemName: "trash") }
                            .help("Clear Terminal")
                        Button { store.toggleEditorTerminal() } label: { Image(systemName: "xmark") }
                            .help("Hide Terminal · ⌥`")
                    }.font(.system(size: 11)).buttonStyle(.plain)
                        .padding(.horizontal, 12).frame(height: 30).background(Theme.panel)
                    TerminalTextView(session: store.terminal, focusOnOpen: true)
                }.frame(minHeight: 100, idealHeight: 220)
            }
        }
    }
}
