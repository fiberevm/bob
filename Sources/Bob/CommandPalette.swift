import SwiftUI
import AppKit
import BobCore

struct CommandPalette: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var model: CommandPaletteModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope: CommandPaletteScope
    @State private var selection = CommandPaletteSelection()
    @State private var pendingAction: (() -> Void)?

    init(store: AppStore) {
        self.store = store
        model = store.commandPalette
        _scope = State(initialValue: store.paletteScope)
    }

    private var commands: [PaletteCommand] {
        guard scope != .files else { return [] }
        return PaletteCommand.allCases.compactMap { command -> (PaletteCommand, Int)? in
            guard command.isAvailable(in: store), let score = CommandSearch.score(query, title: command.title) else { return nil }
            return (command, score)
        }.sorted { $0.1 == $1.1 ? $0.0.order < $1.0.order : $0.1 > $1.1 }.map(\.0)
    }
    private var files: [ProjectFile] { scope == .commands || model.matchedQuery != query ? [] : model.matches }
    private var resultIDs: [String] { commands.map(\.id) + files.map { "file:" + $0.id } }
    private var isLoading: Bool { scope != .commands && (model.isIndexing || model.isSearching) }
    private var placeholder: String {
        switch scope {
        case .all: return "Search commands and files…"
        case .files: return "Search project files…"
        case .commands: return "Search commands…"
        }
    }
    private struct SearchRequest: Equatable { let query: String; let generation: Int; let scope: CommandPaletteScope }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Theme.line.frame(height: 1)
            scopeBar
            results
            Theme.line.frame(height: 1)
            footer
        }
        .frame(width: 620, height: 490)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .onAppear { selection.reconcile(resultIDs) }
        .onChange(of: query) { _, _ in selection.reconcile(resultIDs, reset: true) }
        .onChange(of: scope) { _, _ in selection.reconcile(resultIDs, reset: true) }
        .onChange(of: resultIDs) { _, ids in selection.reconcile(ids) }
        .task(id: store.projectPath) { await model.load(projectPath: store.projectPath) }
        .task(id: SearchRequest(query: query, generation: model.generation, scope: scope)) {
            if scope != .commands { await model.search(query) }
        }
        .onDisappear {
            if let action = pendingAction { pendingAction = nil; DispatchQueue.main.async(execute: action) }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.muted)
            PaletteSearchField(text: $query, placeholder: placeholder, onMove: move, onSubmit: activateSelection,
                               onEscape: { dismiss() }, onSwitchScope: cycleScope)
                .frame(height: 28)
            if isLoading { ProgressView().controlSize(.small).accessibilityLabel("Searching project files") }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }.buttonStyle(.plain).focusable(false).help("Clear Search").accessibilityLabel("Clear search")
            }
            Button { dismiss() } label: { PaletteKeycap(label: "esc") }
                .buttonStyle(.plain).focusable(false).help("Close Command Center")
        }.padding(.horizontal, 20).frame(height: 66)
    }

    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(CommandPaletteScope.allCases) { item in
                Button { scope = item } label: {
                    Text(item.rawValue).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(scope == item ? Theme.text : Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(scope == item ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).focusable(false)
                    .accessibilityAddTraits(scope == item ? .isSelected : [])
            }
            Spacer(minLength: 12)
            if !store.projectPath.isEmpty {
                Label(URL(fileURLWithPath: store.projectPath).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
        }.padding(.horizontal, 12).frame(height: 43)
    }

    private var results: some View {
        ScrollViewReader { reader in
            FadingScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !commands.isEmpty {
                        sectionLabel(query.isEmpty ? "Suggested commands" : "Commands")
                        ForEach(commands) { command in
                            resultRow(id: command.id, title: command.title, symbol: command.symbol, shortcut: command.shortcut) {
                                activate(command)
                            }
                        }
                    }
                    if scope != .commands, let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.warning).padding(12)
                    }
                    if !files.isEmpty {
                        sectionLabel("Project files")
                        ForEach(files) { file in
                            resultRow(id: "file:" + file.id, title: file.name, subtitle: file.directory,
                                      filePath: absolutePath(file), isOpen: store.openTabs.contains { store.buffer(for: $0.id)?.path == absolutePath(file) }) {
                                open(file)
                            }
                        }
                    }
                    if resultIDs.isEmpty && model.error == nil {
                        VStack(spacing: 10) {
                            Image(systemName: isLoading ? "magnifyingglass" : "doc.text.magnifyingglass")
                                .font(.system(size: 25, weight: .light)).foregroundStyle(Theme.muted)
                            Text(isLoading ? "Searching project files…" : query.isEmpty ? "No files to show" : "No results for “\(query)”")
                                .font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text(store.projectPath.isEmpty && scope == .files ? "Open a project to find its files." : "Search by filename, path, or command name.")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 64).padding(.horizontal, 20)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
            .onChange(of: selection.selectedID) { _, id in if let id { reader.scrollTo(id) } }
        }.frame(maxHeight: .infinity)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 10).padding(.top, 13).padding(.bottom, 6)
    }

    private func resultRow(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, filePath: String? = nil,
                           shortcut: String? = nil, isOpen: Bool = false, action: @escaping () -> Void) -> some View {
        let selected = selection.selectedID == id
        return Button(action: action) {
            HStack(spacing: 11) {
                Group {
                    if let filePath { FileIcon(path: filePath, size: 18) }
                    else { Image(systemName: symbol ?? "doc").font(.system(size: 14)).foregroundStyle(selected ? Theme.text : Theme.secondary) }
                }.frame(width: 20)
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 6)
                if isOpen { Text("Open").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                if let shortcut { PaletteKeycap(label: shortcut) }
                else if selected { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 10).frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false).id(id)
        .onHover { if $0 { selection.selectedID = id } }
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(subtitle.map { $0 == "." ? title : $0 + "/" + title } ?? title)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) { PaletteKeycap(label: "↑"); PaletteKeycap(label: "↓"); Text("Navigate") }
            HStack(spacing: 5) { PaletteKeycap(label: "⇥"); Text("Filter") }
            Spacer()
            HStack(spacing: 5) {
                Text(selection.selectedID?.hasPrefix("file:") == true ? "Open file" : "Run command")
                PaletteKeycap(label: "↵")
            }
        }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 16).frame(height: 40).background(Theme.panel)
    }

    private func move(_ offset: Int) { selection.move(by: offset, in: resultIDs) }
    private func cycleScope(_ backwards: Bool) {
        let scopes = CommandPaletteScope.allCases, index = scopes.firstIndex(of: scope) ?? 0
        scope = scopes[(index + (backwards ? scopes.count - 1 : 1)) % scopes.count]
    }
    private func activateSelection() {
        if let command = commands.first(where: { $0.id == selection.selectedID }) { activate(command) }
        else if let file = files.first(where: { "file:" + $0.id == selection.selectedID }) { open(file) }
    }
    private func activate(_ command: PaletteCommand) {
        if command == .findFile { query = ""; scope = .files; return }
        pendingAction = { command.perform(in: store) }; dismiss()
    }
    private func open(_ file: ProjectFile) {
        pendingAction = { store.openFile(file.relativePath, focusEditor: true) }; dismiss()
    }
    private func absolutePath(_ file: ProjectFile) -> String {
        URL(fileURLWithPath: store.projectPath).appendingPathComponent(file.relativePath).path
    }
}

private struct PaletteKeycap: View {
    let label: String
    var body: some View {
        Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 0.5) }
    }
}

private enum PaletteCommand: String, CaseIterable, Identifiable {
    case findFile, newChat, openProject, settings, terminal, reviewChanges, editor, plan, changes, browser, computer, simulator, saveFile, closeTab, refresh, undo, stop
    var id: String { "command:" + rawValue }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var title: String {
        switch self {
        case .findFile: return "Find file…"
        case .newChat: return "New chat"
        case .openProject: return "Open project…"
        case .settings: return "Settings…"
        case .terminal: return "Show terminal"
        case .reviewChanges: return "Review changes"
        case .editor: return "Show editor"
        case .plan: return "Show plan"
        case .changes: return "Show changes"
        case .browser: return "Show browser"
        case .computer: return "Show computer"
        case .simulator: return "Show simulator"
        case .saveFile: return "Save file"
        case .closeTab: return "Close tab"
        case .refresh: return "Refresh project"
        case .undo: return "Undo last Bob file edit"
        case .stop: return "Stop agent"
        }
    }
    var symbol: String {
        switch self {
        case .findFile: return "doc.text.magnifyingglass"
        case .newChat: return "square.and.pencil"
        case .openProject: return "folder"
        case .settings: return "slider.horizontal.3"
        case .terminal: return "terminal"
        case .reviewChanges: return "text.magnifyingglass"
        case .editor: return "curlybraces"
        case .plan: return "list.bullet.rectangle"
        case .changes: return "arrow.triangle.branch"
        case .browser: return "globe"
        case .computer: return "desktopcomputer"
        case .simulator: return "iphone"
        case .saveFile: return "square.and.arrow.down"
        case .closeTab: return "xmark"
        case .refresh: return "arrow.clockwise"
        case .undo: return "arrow.uturn.backward"
        case .stop: return "stop.circle"
        }
    }
    var shortcut: String? {
        switch self {
        case .findFile: return "⌘ P"
        case .newChat: return "⌘ N"
        case .openProject: return "⌘ O"
        case .settings: return "⌘ ,"
        case .terminal: return "⌘ J"
        case .editor: return "⌥ ⌘ 1"
        case .changes: return "⌥ ⌘ 2"
        case .browser: return "⌥ ⌘ 3"
        case .computer: return "⌥ ⌘ 4"
        case .simulator: return "⌥ ⌘ 5"
        case .plan: return "⌥ ⌘ 6"
        case .saveFile: return "⌘ S"
        case .closeTab: return "⌘ W"
        case .stop: return "⌘ ."
        default: return nil
        }
    }
    @MainActor func isAvailable(in store: AppStore) -> Bool {
        switch self {
        case .openProject, .settings: return true
        case .closeTab: return store.canCloseSelectedTab
        case .saveFile: return store.editorDirty
        case .undo: return !store.checkpoints.isEmpty && !store.hasUnsavedEdits
        case .stop: return store.isRunning
        case .reviewChanges: return store.git.isRepository
        default: return !store.projectPath.isEmpty
        }
    }
    @MainActor func perform(in store: AppStore) {
        switch self {
        case .findFile: store.openCommandPalette(scope: .files)
        case .newChat: store.newSession()
        case .openProject: store.openProject()
        case .settings: store.showSettings = true
        case .terminal: store.startTerminal()
        case .reviewChanges: store.reviewChanges()
        case .editor: store.openPanel(.editor)
        case .plan: store.openPanel(.plan)
        case .changes: store.openPanel(.changes)
        case .browser: store.openPanel(.browser)
        case .computer: store.openPanel(.computer)
        case .simulator: store.openPanel(.simulator)
        case .saveFile: store.saveFile()
        case .closeTab: store.closeSelectedTab()
        case .refresh: store.refresh()
        case .undo: store.undoFile()
        case .stop: store.stop()
        }
    }
}

/// Handle list navigation in the field editor, before AppKit consumes arrow keys.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onSwitchScope: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = FocusedPaletteField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search commands and project files")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            // Preserve arrows, Return, and Escape for IME candidate selection while composing.
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            case #selector(NSResponder.insertTab(_:)): parent.onSwitchScope(false)
            case #selector(NSResponder.insertBacktab(_:)): parent.onSwitchScope(true)
            default: return false
            }
            return true
        }
    }
}

private final class FocusedPaletteField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}
