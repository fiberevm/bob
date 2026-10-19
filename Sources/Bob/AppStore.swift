import SwiftUI
import AppKit
import Combine
import CryptoKit
import BobCore

@MainActor final class AppStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            draft = selected?.promptDraft ?? ""
            draftImages = []
            scheduleSave()
        }
    }
    var settings: ProviderSettings {
        get { connections.settings }
        set { connections.settings = newValue }
    }
    @Published var draft = "" {
        didSet {
            guard oldValue != draft, let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
            sessions[index].promptDraft = draft.isEmpty ? nil : draft
            scheduleSave()
        }
    }
    @Published var draftImages: [PromptAttachment] = []
    @Published private(set) var composerFocusRequest: UUID?
    @Published private(set) var lastCreatedSessionID: UUID?
    @Published private(set) var lastSubmittedMessage: Message?
    private(set) var lastSubmittedSessionID: UUID?
    @Published private var runs: [UUID: SessionRun] = [:]
    // Composer, model menus, and Stop always describe the selected chat.
    var isRunning: Bool { selectedID.map { runs[$0] != nil } ?? false }
    var runningSessionIDs: Set<UUID> { Set(runs.keys) }
    /// All live chats, including those not selected in this project window.
    var runningChatActivities: [RunningChatActivity] {
        sessions.compactMap { session in
            guard let run = runs[session.id] else { return nil }
            return RunningChatActivity(id: session.id, title: session.title,
                                       activity: run.activity, needsApproval: run.approval != nil || run.userInput != nil)
        }
    }
    @Published private var workspaceActivity = "Ready"
    var activity: String { selectedID.flatMap { runs[$0]?.activity } ?? workspaceActivity }
    var approval: ApprovalRequest? { selectedID.flatMap { runs[$0]?.approval } }
    var userInput: UserInputRequest? { selectedID.flatMap { runs[$0]?.userInput } }
    @Published var error: String?
    @Published var showSettings = false
    var showWorkspacePanel: Bool { !boundProjectPath.isEmpty }
    @Published private(set) var showEditorTerminal = false
    @Published var showPalette = false
    var paletteScope: CommandPaletteScope = .all
    @Published private(set) var openTabs: [WorkspaceTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published private var editorBuffers: [UUID: EditorBuffer] = [:]
    private var activeEditorTabID: UUID?
    let fileTree = FileTree()
    let commandPalette = CommandPaletteModel()
    @Published private(set) var isMutatingFiles = false
    private var fileMutationGeneration = UUID()
    private let completionAlert: @MainActor (Session, UUID) -> Void
    private let trashItem: WorkspaceTrashHandler
    @Published var git = GitState()
    @Published var checkpoints: [FileCheckpoint] = [] {
        didSet {
            var changes: [String: FileChangeKind] = [:]
            for (path, history) in Dictionary(grouping: checkpoints, by: \.path) {
                guard let first = history.last, let latest = history.first else { continue }
                if let before = first.before,
                   SHA256.hash(data: before).map({ String(format: "%02x", $0) }).joined() == latest.afterHash { continue }
                changes[path] = first.before == nil ? .added : .modified
            }
            checkpointFileChanges = changes
        }
    }
    private var checkpointFileChanges: [String: FileChangeKind] = [:]
    @Published var editorPath: String?
    @Published var editorText = ""
    @Published var editorOriginal = ""
    @Published private(set) var editorFocusRequest: UUID?
    var auth: ChatGPTAuth { connections.auth }
    var modelGroups: [ProviderModelGroup] { connections.modelGroups(including: selected) }
    @Published var settingsProvider: ProviderKind = .chatgpt
    let terminal = TerminalSession()
    let browser = BrowserSession()
    let computer = ComputerSession()
    let simulator = SimulatorSession()
    let dataDirectory: URL
    private let persistence: WorkspacePersistence
    let boundProjectPath: String
    var onOpenProject: ((String) -> Void)?
    let connections: ConnectionPreferences
    private var connectionsObservation: AnyCancellable?
    private var browserObservation: AnyCancellable?
    private var fileServices: [String: WorkspaceFiles] = [:]
    private let surfaceCoordinator = AgentSurfaceCoordinator()
    private final class SessionRun {
        let harness: AgentHarness
        let id: UUID
        let input = AgentInput()
        var waitingForSteering = false
        var followUps: [Message] = []
        var routingTask: Task<Void, Never>?
        var routingGeneration = 0
        var task: Task<Void, Never>?
        var activity = "Connecting"
        var approval: ApprovalRequest?
        var userInput: UserInputRequest?
        var pendingText = ""
        var textTask: Task<Void, Never>?
        var messageID: UUID?
        init(id: UUID, harness: AgentHarness) { self.id = id; self.harness = harness; messageID = id }
    }
    /// Injectable for deterministic routing tests. Nil preserves immediate steering.
    var followUpRouter: (([ModelMessage], String) async throws -> FollowUpDisposition)? = LocalDecisions.model.map { model in
        { history, message in try await FollowUpDecision.decide(model: model, history: history, message: message) }
    }
    private var saveTask: Task<Void, Never>?
    private var projectTask: Task<Void, Never>?
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var manuallyNamedSessionIDs: Set<UUID> = []
    var generatingTitleSessionIDs: Set<UUID> { Set(titleTasks.keys) }

    typealias WorkspacePanelTab = WorkspacePanelKind
    var selectedTab: WorkspaceTab? { openTabs.first { $0.id == selectedTabID } }
    var canCloseSelectedTab: Bool { selectedTab.map(tabCanClose) ?? false }
    var selectedPanel: WorkspacePanelTab { selectedTab?.kind ?? .editor }
    var selected: Session? { sessions.first { $0.id == selectedID } }
    var selectedContextUsage: ContextUsage {
        if let usage = selected?.contextUsage { return usage }
        let history = selected?.turns ?? []
        if selectedProvider == .claudeCode {
            return ContextUsage(tokens: history.isEmpty ? 0 : ContextManager().estimatedTokens(history), budget: nil, isEstimated: true, source: .provider)
        }
        return ContextManager().usage(history)
    }
    var selectedChatActivity: String? {
        guard isRunning else { return nil }
        if userInput != nil { return "Answer needed" }
        return approval != nil ? "Approval needed" : activity
    }
    enum SessionStatus: String { case working = "Working", done = "Done" }
    func sessionStatus(_ session: Session) -> SessionStatus? {
        if runs[session.id] != nil { return .working }
        guard let response = session.turns.last, response.role == "assistant", response.toolCalls.isEmpty,
              !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let message = session.messages.last, message.role == .assistant,
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .done
    }
    var editorDirty: Bool { editorText != editorOriginal }
    var hasUnsavedEdits: Bool { editorDirty || editorBuffers.contains { $0.key != activeEditorTabID && $0.value.isDirty } }
    var fileChanges: [String: FileChangeKind] {
        var changes = Dictionary(uniqueKeysWithValues: git.changes.map { ($0.path, $0.kind) })
        if !git.isRepository {
            changes.merge(checkpointFileChanges) { existing, _ in existing }
        }
        for tab in openTabs where tab.kind == .editor {
            if let buffer = buffer(for: tab.id), buffer.isDirty, let path = buffer.path, changes[path] == nil { changes[path] = .modified }
        }
        return changes
    }
    var projectPath: String { selected?.projectPath ?? "" }
    var selectedProvider: ProviderKind { selected?.provider ?? .chatgpt }
    var selectedModelID: String {
        guard let selected else { return "" }
        let model = selected.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? connections.defaultModel(for: selected.provider) : model
    }
    var selectedModelName: String {
        guard let group = modelGroups.first(where: { $0.provider == selectedProvider }) else { return "Select model" }
        return group.models.first(where: { $0.id == selectedModelID })?.name ?? "Select model"
    }
    var availableReasoningEfforts: [String] {
        reasoningEfforts(provider: selectedProvider, model: selectedModelID)
    }
    var selectedReasoningEffort: String? {
        guard let effort = selected?.reasoningEffort, availableReasoningEfforts.contains(effort) else { return nil }
        return effort
    }
    func selectReasoningEffort(_ effort: String?) {
        guard !isRunning, let id = selectedID,
              effort == nil || availableReasoningEfforts.contains(effort!) else { return }
        mutate(id) { $0.reasoningEffort = effort }
    }
    private func reasoningEfforts(provider: ProviderKind, model: String) -> [String] {
        let metadata = connections.models(for: provider).first { $0.id == model } ?? AvailableModel(id: model)
        return ModelReasoning.supportedEfforts(provider: provider, model: metadata)
    }

    init(projectPath: String = "", storageDirectory: URL? = nil, connections: ConnectionPreferences? = nil,
         trashItem: @escaping WorkspaceTrashHandler = WorkspaceFiles.systemTrash,
         completionAlert: @escaping @MainActor (Session, UUID) -> Void = { ConversationCompletionAlerts.shared.post(session: $0, runID: $1) }) {
        self.completionAlert = completionAlert
        self.trashItem = trashItem
        self.connections = connections ?? .shared
        if let storageDirectory { dataDirectory = storageDirectory }
        else if let path = ProcessInfo.processInfo.environment["BOB_DATA_DIRECTORY"] { dataDirectory = URL(fileURLWithPath: path) }
        else { dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bob") }
        boundProjectPath = projectPath.isEmpty ? "" : URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(boundProjectPath.utf8)).map { String(format: "%02x", $0) }.joined()
        persistence = WorkspacePersistence(url: dataDirectory.appendingPathComponent("projects").appendingPathComponent(hash + ".json"))
        do {
            let saved = try persistence.load()
            sessions = saved.sessions.filter { $0.projectPath == boundProjectPath }
            selectedID = saved.selectedSessionID ?? sessions.first?.id
        } catch {
            if FileManager.default.fileExists(atPath: persistence.url.path) { self.error = "The saved workspace could not be loaded. It has been preserved on disk. \(error.localizedDescription)" }
        }
        for index in sessions.indices {
            sessions[index].migrateTokenUsage()
            sessions[index].messages.removeAll { $0.role == .activity && $0.tool == nil && $0.text == "Compacting context" }
            do {
                let url = dataDirectory.appendingPathComponent("turns").appendingPathComponent(sessions[index].id.uuidString + ".jsonl")
                guard let recovered = try TurnJournal.recover(from: url),
                      let assistant = sessions[index].messages.firstIndex(where: { $0.id == recovered.runID }),
                      assistant > (sessions[index].messages.lastIndex(where: { $0.role == .user && $0.isSteering != true }) ?? -1) else { continue }
                let needsRestore = recovered.interrupted || sessions[index].turns != recovered.history || sessions[index].messages.contains { $0.tool?.status == .running }
                if needsRestore { sessions[index].contextUsage = nil }
                if let id = recovered.backendSessionID { sessions[index].claudeCodeSessionID = id }
                for (id, usage) in recovered.usageRecords { sessions[index].recordTokenUsage(.init(id: id, usage: usage)) }
                let originalUser = sessions[index].messages[..<assistant].last { $0.role == .user }
                let applied = Set(recovered.history.compactMap(\.userMessageID))
                let pending = sessions[index].messages.dropFirst(assistant).filter { $0.isSteering == true && !applied.contains($0.id) }
                let history = recovered.history + pending.map { ModelMessage(role: "user", text: $0.text, images: $0.images ?? [], userMessageID: $0.id) }
                sessions[index].turns = history
                if needsRestore {
                    let notices = sessions[index].messages.dropFirst(assistant).filter { $0.role == .error || ($0.role == .activity && $0.tool == nil) }
                    let restored = ChatTranscript.recoveredMessages(history: history, runID: recovered.runID, reviews: recovered.reviews, delegatedTools: recovered.delegatedTools, startingAfter: originalUser?.id)
                    sessions[index].messages.replaceSubrange(assistant..., with: restored + notices)
                }
                let notice = "Recovered interrupted work. Inspect current state before repeating any unfinished operation."
                if recovered.interrupted, sessions[index].messages.last?.text != notice { sessions[index].messages.append(Message(role: .activity, text: notice)) }
            } catch { self.error = "Could not recover the agent journal: \(error.localizedDescription)" }
        }
        if sessions.isEmpty {
            if !boundProjectPath.isEmpty { let session = Session(projectPath: boundProjectPath); sessions = [session]; selectedID = session.id }
        }
        draft = selected?.promptDraft ?? ""
        connectionsObservation = self.connections.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !boundProjectPath.isEmpty {
            var recent = UserDefaults.standard.stringArray(forKey: "projects.recent") ?? []
            recent.removeAll { $0 == boundProjectPath }; recent.insert(boundProjectPath, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(20)), forKey: "projects.recent")
            UserDefaults.standard.set(boundProjectPath, forKey: "projects.last")
        }
        loadProject()
        configureBrowser()
        browserObservation = browser.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        computer.onAgentUse = { [weak self] in self?.openPanel(.computer) }
        computer.onTakeover = { [weak self] in
            guard let self, let owner = surfaceCoordinator.owners[.computer],
                  let sessionID = runs.first(where: { $0.value.id == owner })?.key else { return }
            stop(sessionID: sessionID)
        }
    }
    func fileService(path: String) -> WorkspaceFiles {
        if let service = fileServices[path] { return service }
        let service = WorkspaceFiles(root: URL(fileURLWithPath: path), checkpointDirectory: dataDirectory.appendingPathComponent("checkpoints"), trashItem: trashItem)
        fileServices[path] = service; return service
    }
    func mutate(_ id: UUID, _ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[index]); sessions[index].updatedAt = Date(); scheduleSave()
    }
    func selectModel(_ model: AvailableModel, provider: ProviderKind) {
        guard let current = selected, !isRunning else { return }
        if current.provider != provider && (!current.messages.isEmpty || !current.turns.isEmpty) {
            let prompt = draft
            let attachments = draftImages
            newSession(provider: provider)
            guard selectedID != current.id else { return }
            draft = prompt
            draftImages = attachments
        }
        guard let id = selectedID else { return }
        mutate(id) { $0.provider = provider; $0.model = model.id; $0.contextUsage = nil }
    }
    func setModel(_ model: String) {
        guard let id = selectedID, !isRunning else { return }
        mutate(id) { $0.model = model; $0.contextUsage = nil }
    }
    func newSession(provider: ProviderKind? = nil) {
        guard let current = selected else { openProject(); return }
        defer { composerFocusRequest = UUID() }
        if current.messages.isEmpty && current.turns.isEmpty && !isRunning {
            if let provider, provider != current.provider {
                mutate(current.id) { $0.provider = provider; $0.model = "" }
            }
            return
        }
        let session = Session(projectPath: current.projectPath, provider: provider ?? current.provider)
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .easeInOut(duration: 0.24)
        withAnimation(animation) {
            sessions.insert(session, at: 0)
            selectedID = session.id
            lastCreatedSessionID = session.id
        }
        scheduleSave()
    }
    func renameSession(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, sessions.contains(where: { $0.id == id }) else { return }
        manuallyNamedSessionIDs.insert(id)
        titleTasks[id]?.cancel()
        mutate(id) { $0.title = name }
    }
    func deleteSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let deleted = sessions[index]
        stop(sessionID: id)
        sessions.remove(at: index)
        manuallyNamedSessionIDs.remove(id)
        if selectedID == id {
            if sessions.isEmpty {
                sessions = [Session(projectPath: deleted.projectPath, provider: deleted.provider)]
            }
            selectedID = sessions[min(index, sessions.count - 1)].id
        }
        scheduleSave()
    }
    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        composerFocusRequest = UUID()
    }
    func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open Project"; panel.message = "Choose the folder Bob should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onOpenProject?(url.standardizedFileURL.resolvingSymlinksInPath().path)
    }
    func openCommandPalette(scope: CommandPaletteScope = .all) {
        paletteScope = scope; showPalette = true
    }
    func loadProject() {
        fileMutationGeneration = UUID()
        projectTask?.cancel()
        openTabs = []; selectedTabID = nil; editorBuffers = [:]; activeEditorTabID = nil
        editorPath = nil; editorText = ""; editorOriginal = ""
        fileTree.reset(); git = GitState(); checkpoints = []
        commandPalette.start(projectPath: projectPath)
        guard !projectPath.isEmpty else { return }
        openPanel(.editor)
        let path = projectPath
        let service = fileService(path: path)
        fileTree.reset(files: service)
        projectTask = Task {
            do {
                try await fileTree.refresh()
                let history = await service.history()
                let state = try await GitService.inspect(directory: URL(fileURLWithPath: path))
                guard !Task.isCancelled, projectPath == path else { return }
                checkpoints = history; git = state
                fileTree.setChangedPaths(Set(fileChanges.keys))
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        if terminal.directory != path { terminal.stop() }
    }
    func refresh() {
        guard !projectPath.isEmpty else { return }
        commandPalette.refresh()
        Task {
            do { try await refreshProjectState() }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func refreshProjectState() async throws {
        // A startup snapshot must not overwrite newer file/checkpoint state after a mutation.
        projectTask?.cancel(); projectTask = nil
        let path = projectPath
        let service = fileService(path: path)
        try await fileTree.refresh()
        let state = try await GitService.inspect(directory: URL(fileURLWithPath: path))
        let history = await service.history()
        guard projectPath == path, !Task.isCancelled else { return }
        git = state; checkpoints = history
        fileTree.setChangedPaths(Set(fileChanges.keys))
        await refreshEditorBuffers(files: service)
    }
    private func beginFileTreeMutation() throws {
        guard !projectPath.isEmpty else { throw BobError.message("Open a project first.") }
        guard !isMutatingFiles else { throw BobError.message("Another file operation is still in progress.") }
        isMutatingFiles = true; fileMutationGeneration = UUID()
    }
    func createFileTreeItem(named name: String, in directory: String, isDirectory: Bool) async throws {
        try beginFileTreeMutation()
        defer { isMutatingFiles = false }
        let item = try await fileService(path: projectPath).createItem(named: name, in: directory, isDirectory: isDirectory)
        if !isDirectory {
            _ = try await openFileTab(item.path, forFileMutation: true)
            editorFocusRequest = UUID()
        }
        await finishFileTreeMutation(reveal: item)
    }
    func renameFileTreeItem(_ path: String, to name: String) async throws {
        try beginFileTreeMutation()
        defer { isMutatingFiles = false }
        let move = try await fileService(path: projectPath).renameItem(path, to: name)
        stashEditor()
        for id in Array(editorBuffers.keys) {
            if let oldPath = editorBuffers[id]?.path {
                editorBuffers[id]?.path = WorkspaceFiles.remap(oldPath, from: move.from, to: move.to)
            }
        }
        if let editorPath { self.editorPath = WorkspaceFiles.remap(editorPath, from: move.from, to: move.to) }
        fileTree.remapExpandedPaths(from: move.from, to: move.to)
        if path != move.from {
            fileTree.remapExpandedPaths(from: path, to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name).path)
        }
        await finishFileTreeMutation()
    }
    func trashFileTreeItem(_ path: String) async throws {
        try beginFileTreeMutation()
        defer { isMutatingFiles = false }
        let service = fileService(path: projectPath)
        let source = try await service.fileTreeItemPath(path)
        let affected = openTabs.filter { tab in
            tab.kind == .editor && buffer(for: tab.id)?.path.map { WorkspaceFiles.contains($0, in: source) } == true
        }
        guard !affected.contains(where: tabIsDirty) else {
            throw BobError.message("Save or discard unsaved changes in this item before moving it to Trash.")
        }
        _ = try await service.trashItemAtPath(source)
        for tab in affected { try closeTab(tab.id) }
        fileTree.removeExpandedPaths(under: source)
        await finishFileTreeMutation()
    }
    private func finishFileTreeMutation(reveal item: FileEntry? = nil) async {
        do {
            try await refreshProjectState()
            if let item { try await fileTree.reveal(item) }
        } catch { self.error = "The item was changed, but the project could not be refreshed. \(error.localizedDescription)" }
    }
    func openFile(_ path: String, focusEditor: Bool = false) {
        Task {
            do {
                _ = try await openFileTab(path)
                if focusEditor { editorFocusRequest = UUID() }
            } catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult func openFileTab(_ path: String, forFileMutation: Bool = false) async throws -> UUID {
        guard !projectPath.isEmpty else { throw BobError.message("Open a project first.") }
        guard !isMutatingFiles || forFileMutation else { throw BobError.message("A file operation is still in progress. Try opening the file again.") }
        let generation = fileMutationGeneration
        let service = fileService(path: projectPath)
        let resolved = try await service.resolve(path).path
        if let existing = fileTab(at: resolved) { selectTab(existing.id); return existing.id }
        let text: String
        do { text = try await service.read(resolved) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile && fileChanges[resolved] == .deleted { text = "" }
        try Task.checkCancellation()
        guard generation == fileMutationGeneration else { throw BobError.message("The project files changed. Open this file again.") }
        // Another open may have completed while the file was being read.
        if let existing = fileTab(at: resolved) { selectTab(existing.id); return existing.id }
        let tab: WorkspaceTab
        if let current = openTabs.first(where: { $0.id == activeEditorTabID && $0.kind == .editor && !tabIsDirty($0) }) {
            tab = current
        } else if let empty = openTabs.first(where: { $0.kind == .editor && buffer(for: $0.id)?.path == nil && !tabIsDirty($0) }) {
            tab = empty
        } else {
            tab = WorkspaceTab(.editor); openTabs.append(tab)
        }
        if activeEditorTabID == tab.id { activeEditorTabID = nil }
        editorBuffers[tab.id] = EditorBuffer(path: resolved, text: text, original: text)
        selectTab(tab.id)
        return tab.id
    }
    func comparisonBase(for path: String, fallback: String) async throws -> (text: String, label: String) {
        if git.isRepository {
            let change = git.changes.first { $0.path == path }
            if change?.kind == .added || change?.kind == .untracked { return ("", "New file") }
            if let repository = git.repositoryRoot, let revision = git.revision,
               let text = try await GitService.originalText(path: change?.originalPath ?? path, repository: URL(fileURLWithPath: repository), revision: revision) {
                return (text, "HEAD")
            }
        } else if let checkpoint = checkpoints.last(where: { $0.path == path }) {
            guard let before = checkpoint.before else { return ("", "Before Bob edits") }
            guard !before.contains(0), let text = String(data: before, encoding: .utf8) else { throw BobError.message("The original file is not UTF-8 text.") }
            return (text, "Before Bob edits")
        }
        return (fallback, "Saved file")
    }
    private func refreshEditorBuffers(files: WorkspaceFiles) async {
        for tab in openTabs where tab.kind == .editor {
            guard let previous = buffer(for: tab.id), !previous.isDirty, let path = previous.path else { continue }
            let text: String
            do { text = try await files.read(path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile && fileChanges[path] == .deleted { text = "" }
            catch { continue }
            guard !Task.isCancelled, let current = buffer(for: tab.id), !current.isDirty,
                  current.path == path, current.original == previous.original else { continue }
            if activeEditorTabID == tab.id { editorText = text; editorOriginal = text }
            else { editorBuffers[tab.id] = EditorBuffer(path: path, text: text, original: text) }
        }
    }
    func saveFile() {
        guard let editorPath else { return }
        let content = editorText, expected = editorOriginal, path = projectPath, tabID = activeEditorTabID
        let service = fileService(path: path)
        Task {
            do {
                try await service.write(editorPath, text: content, expected: expected)
                if activeEditorTabID == tabID, self.editorPath == editorPath { editorOriginal = content }
                else if let tabID, var buffer = editorBuffers[tabID], buffer.path == editorPath {
                    buffer.original = content; editorBuffers[tabID] = buffer
                }
                refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
    func undoFile() {
        guard !hasUnsavedEdits else { error = "Save or discard unsaved files before undoing a file edit."; return }
        let service = fileService(path: projectPath)
        Task {
            do {
                let restored = checkpoints.first?.path
                let name = try await service.undo(); workspaceActivity = "Restored \(name)"
                if let restored, let tab = fileTab(at: restored) {
                    let text: String
                    do { text = try await service.read(restored) }
                    catch let failure as CocoaError where failure.code == .fileReadNoSuchFile { text = "" }
                    if let current = buffer(for: tab.id), current.path == restored, !current.isDirty {
                        if activeEditorTabID == tab.id { editorText = text; editorOriginal = text }
                        else { editorBuffers[tab.id] = EditorBuffer(path: restored, text: text, original: text) }
                    }
                }
                refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
    func send(transport: (any ModelTransport)? = nil, reviewer: (any ToolSafetyReviewing)? = nil, titleTransport: (any ModelTransport)? = nil) {
        let images = draftImages.map(\.image)
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty, let session = selected else { return }
        let prompt = text.isEmpty ? "Please look at the attached images." : text
        if let run = runs[session.id] {
            let user = Message(role: .user, text: prompt, isSteering: true, images: images)
            mutate(session.id) { $0.messages.append(user) }
            if let router = followUpRouter {
                run.followUps.append(user)
                run.routingGeneration += 1
                let previous = run.routingTask
                let history = session.turns
                run.routingTask = Task {
                    await previous?.value
                    guard !Task.isCancelled else { return }
                    let disposition = (try? await router(history, prompt)) ?? .steer
                    guard !Task.isCancelled, runs[session.id] === run else { return }
                    if disposition == .steer {
                        // Deliver earlier queued messages first to preserve submission order.
                        let index = run.followUps.firstIndex { $0.id == user.id }!
                        let updates = Array(run.followUps.prefix(index + 1))
                        run.followUps.removeFirst(index + 1)
                        for update in updates { steer(update, sessionID: session.id, run: run) }
                    }
                }
            } else {
                steer(user, sessionID: session.id, run: run)
            }
            draft = ""; draftImages = []
            lastSubmittedSessionID = session.id; lastSubmittedMessage = user
            saveNow()
            return
        }
        guard !hasUnsavedEdits else { error = "Save or discard unsaved files before starting the agent."; return }
        draft = ""; draftImages = []
        let userMessage = Message(role: .user, text: prompt, images: images)
        let message = Message(role: .assistant, text: "")
        let harness = AgentHarness(reviewer: reviewer)
        let run = SessionRun(id: message.id, harness: harness)
        let needsTitle = !manuallyNamedSessionIDs.contains(session.id) && session.messages.isEmpty && session.turns.isEmpty && session.title == "New Chat"
        let fallbackTitle = ConversationTitle.fallback(for: prompt)
        runs[session.id] = run
        mutate(session.id) {
            if needsTitle { $0.title = fallbackTitle }
            $0.messages.append(userMessage); $0.messages.append(message)
            $0.turns.append(ModelMessage(role: "user", text: prompt, images: images, userMessageID: userMessage.id))
        }
        // Persist the UI run identity before the journal can record side effects.
        do { try persistence.save(WorkspaceSnapshot(sessions: sessions, selectedSessionID: selectedID, settings: settings)) }
        catch { runs[session.id] = nil; self.error = "Could not save the new turn: \(error.localizedDescription)"; return }
        lastSubmittedSessionID = session.id
        lastSubmittedMessage = userMessage
        harness.onEvent = { [weak self] event in
            guard let self, runs[session.id] === run else { return }
            objectWillChange.send()
            switch event {
            case .text(let text):
                guard !text.isEmpty, !run.waitingForSteering else { return }
                if run.messageID == nil {
                    let next = Message(role: .assistant, text: "")
                    run.messageID = next.id
                    mutate(session.id) { $0.messages.append(next) }
                }
                enqueueText(text, sessionID: session.id, run: run)
            case .activity(let text):
                run.activity = text
                if text.hasPrefix("computer_") { openPanel(.computer) }
                if text != "Thinking" && text != "Compacting context" { mutate(session.id) { $0.messages.append(Message(role: .activity, text: text)) } }
            case .approval(let request): run.approval = request
            case .userInput(let request): run.userInput = request
            case .userAnswer(let text):
                flushText(sessionID: session.id, run: run)
                mutate(session.id) { $0.messages.append(Message(role: .user, text: text)) }
                saveNow()
            case .history(let history): mutate(session.id) { $0.turns = history }
            case .usage(let record): mutate(session.id) { $0.recordTokenUsage(record) }
            case .context(let usage): mutate(session.id) { $0.contextUsage = usage }
            case .backendSession(let id): mutate(session.id) { $0.claudeCodeSessionID = id }
            case .steered: run.waitingForSteering = false
            case .tool(let tool):
                flushText(sessionID: session.id, run: run)
                run.messageID = nil
                run.activity = tool.title
                if tool.call.name.hasPrefix("computer_") { openPanel(.computer) }
                mutate(session.id) { session in
                    if let index = session.messages.lastIndex(where: { $0.tool?.id == tool.id }) { session.messages[index].tool = tool }
                    else { session.messages.append(Message(role: .activity, text: "", tool: tool)) }
                }
            }
        }
        let history = sessions.first { $0.id == session.id }?.turns ?? []
        // Keep authorization grounded in original user text after model context
        // compaction; an assistant-generated summary cannot grant permissions.
        let userRequests = sessions.first { $0.id == session.id }?.messages.filter { $0.role == .user }.map(\.text) ?? []
        let files = fileService(path: session.projectPath)
        let journal = TurnJournal(url: dataDirectory.appendingPathComponent("turns").appendingPathComponent(session.id.uuidString + ".jsonl"))
        let surfaces = AgentSurfaceAccess(runID: message.id, coordinator: surfaceCoordinator, tabKind: { [weak self] id in
            self?.openTabs.first { $0.id == id }?.kind
        })
        run.task = Task {
            defer {
                flushText(sessionID: session.id, run: run)
                mutate(session.id) { session in
                    let pending = run.input.takePending() + run.followUps.map {
                        ModelMessage(role: "user", text: $0.text, images: $0.images ?? [], userMessageID: $0.id)
                    }
                    if !pending.isEmpty { session.turns = ConversationHistory.repaired(session.turns) + pending }
                    for index in session.messages.indices where session.messages[index].tool?.status == .running {
                        session.messages[index].tool?.finish(output: "Interrupted. Inspect current state before repeating this operation.", cancelled: true)
                    }
                }
                harness.onEvent = nil
                run.task = nil
                runs[session.id] = nil
                refresh(); scheduleSave()
            }
            do {
                let configuration = try await configuration(for: session)
                try Task.checkCancellation()
                // Injected agent transports stay isolated from title requests unless
                // a separate title transport is supplied by the caller.
                if needsTitle && (transport == nil || titleTransport != nil) {
                    generateTitle(sessionID: session.id, messageID: userMessage.id, prompt: prompt, fallback: fallbackTitle,
                                  configuration: configuration, transport: titleTransport)
                }
                var current = history
                repeat {
                    current = try await harness.run(configuration: configuration, messages: current, userRequests: userRequests, files: files, project: session.projectPath, transport: transport, browser: browser, computer: computer, workspace: self, workspaceSessionID: session.id, journal: journal, runID: message.id, surfaces: surfaces,
                        claudeExecutable: connections.claude.executable, claudeSessionID: sessions.first { $0.id == session.id }?.claudeCodeSessionID, input: run.input)
                    mutate(session.id) { $0.turns = current }
                    // Wait for routing, including messages submitted while an earlier
                    // classification was running, before declaring this run complete.
                    while let routing = run.routingTask {
                        let generation = run.routingGeneration
                        await routing.value
                        if generation == run.routingGeneration { run.routingTask = nil }
                    }
                    try Task.checkCancellation()
                    let queued = run.followUps
                    run.followUps = []
                    for update in queued {
                        run.input.send(update.text, id: update.id, images: update.images ?? [])
                    }
                    // Input can arrive while a backend flushes its final result.
                    // This check and run cleanup share the main actor with Send.
                } while run.input.hasPending
                try Task.checkCancellation()
                if let completed = sessions.first(where: { $0.id == session.id }) {
                    completionAlert(completed, run.id)
                }
            } catch is CancellationError {
                mutate(session.id) { $0.messages.append(Message(role: .activity, text: "Stopped. Send a follow-up to continue.")) }
            } catch {
                mutate(session.id) { $0.messages.append(Message(role: .error, text: error.localizedDescription)) }
            }
        }
    }
    private func steer(_ user: Message, sessionID: UUID, run: SessionRun) {
        flushText(sessionID: sessionID, run: run)
        run.messageID = nil; run.waitingForSteering = true; run.activity = "Steering"
        run.input.send(user.text, id: user.id, images: user.images ?? [])
        run.harness.steer()
    }

    private func generateTitle(sessionID: UUID, messageID: UUID, prompt: String, fallback: String,
                               configuration: ModelConfiguration, transport: (any ModelTransport)?) {
        guard titleTasks[sessionID] == nil, !manuallyNamedSessionIDs.contains(sessionID),
              sessions.contains(where: { $0.id == sessionID }) else { return }
        var configuration = configuration
        configuration.reasoningEffort = reasoningEfforts(provider: configuration.provider, model: configuration.model).first
        let executable = connections.claude.executable
        titleTasks[sessionID] = Task { [weak self] in
            defer { self?.titleTasks[sessionID] = nil }
            guard let title = try? await ConversationTitle.generate(for: prompt, configuration: configuration,
                claudeExecutable: executable, transport: transport, onUsage: { [weak self] record in
                    await self?.recordTitleUsage(record, sessionID: sessionID)
                }), !Task.isCancelled,
                let self, let index = sessions.firstIndex(where: { $0.id == sessionID }),
                sessions[index].title == fallback,
                sessions[index].messages.first(where: { $0.role == .user })?.id == messageID else { return }
            // Renaming must not move an idle chat above more recent conversations.
            sessions[index].title = title
            scheduleSave()
        }
    }
    func stop() { if let selectedID { stop(sessionID: selectedID) } }
    private func recordTitleUsage(_ record: TokenUsageRecord, sessionID: UUID) {
        mutate(sessionID) { $0.recordTokenUsage(record) }
        saveNow()
    }
    private func stop(sessionID: UUID) {
        runs[sessionID]?.routingTask?.cancel()
        runs[sessionID]?.harness.stop(); runs[sessionID]?.task?.cancel(); titleTasks[sessionID]?.cancel()
    }
    func stopAll() { for id in Set(runs.keys).union(titleTasks.keys) { stop(sessionID: id) } }
    private func configuration(for session: Session) async throws -> ModelConfiguration {
        let token: String, base: String
        switch session.provider {
        case .chatgpt: token = try await auth.accessToken(); base = "https://api.openai.com/v1"
        case .openai: token = try SecretStore.read("openai"); base = "https://api.openai.com/v1"
        case .claude: token = try SecretStore.read("claude"); base = "https://api.anthropic.com/v1"
        case .claudeCode:
            if !connections.claude.checked { await connections.claude.refresh() }
            guard connections.claude.isConnected else { throw BobError.message(connections.claude.error ?? "Connect Claude in Settings first.") }
            token = ""; base = ""
        case .compatible: token = try SecretStore.read("compatible"); base = settings.baseURL
        }
        if ![.compatible, .claudeCode].contains(session.provider) && token.isEmpty { throw BobError.message("Connect \(session.provider.title) in Settings first.") }
        let configured = session.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configured.isEmpty ? connections.defaultModel(for: session.provider) : configured
        guard !model.isEmpty else { throw BobError.message("Choose a model before sending.") }
        let effort = session.reasoningEffort.flatMap { reasoningEfforts(provider: session.provider, model: model).contains($0) ? $0 : nil }
        return ModelConfiguration(provider: session.provider, model: model, baseURL: base, token: token, reasoningEffort: effort)
    }
    private func enqueueText(_ text: String, sessionID: UUID, run: SessionRun) {
        run.pendingText += text
        guard run.textTask == nil else { return }
        run.textTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            flushText(sessionID: sessionID, run: run)
        }
    }
    private func flushText(sessionID: UUID, run: SessionRun) {
        run.textTask?.cancel(); run.textTask = nil
        let text = run.pendingText; run.pendingText = ""
        guard !text.isEmpty, let messageID = run.messageID else { return }
        mutate(sessionID) { session in
            if let index = session.messages.firstIndex(where: { $0.id == messageID }) { session.messages[index].text += text }
        }
    }
    func reviewChanges() {
        draft = "Review the current Git changes. Read the diff and relevant files, identify concrete bugs or regressions with file and line references, and explain any missing validation. Do not change files."
    }
    func readWorkspacePlan(sessionID: UUID?) throws -> String {
        guard let id = sessionID ?? selectedID, let session = sessions.first(where: { $0.id == id }) else {
            throw BobError.message("This chat is no longer available.")
        }
        return session.plan ?? ""
    }
    func updateWorkspacePlan(_ markdown: String, sessionID: UUID?) throws -> String {
        guard let id = sessionID ?? selectedID, let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw BobError.message("This chat is no longer available.")
        }
        guard markdown.utf8.count <= 200_000 else { throw BobError.message("Plans must be at most 200,000 UTF-8 bytes.") }
        var updated = sessions
        updated[index].plan = markdown
        updated[index].updatedAt = Date()
        try persistence.save(WorkspaceSnapshot(sessions: updated, selectedSessionID: selectedID, settings: settings))
        sessions = updated
        if selectedID == id { openPanel(.plan) }
        return "Saved this chat's Markdown plan (\(markdown.utf8.count) bytes)."
    }
    func openPanel(_ tab: WorkspacePanelTab) {
        if tab == .editor, let id = activeEditorTabID, openTabs.contains(where: { $0.id == id }) { selectTab(id); return }
        if let existing = openTabs.first(where: { $0.kind == tab }) { selectTab(existing.id); return }
        let opened = WorkspaceTab(tab)
        openTabs.append(opened)
        if tab == .editor { editorBuffers[opened.id] = EditorBuffer() }
        selectTab(opened.id)
    }
    func selectTab(_ id: UUID) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        if tab.kind == .editor && activeEditorTabID != id {
            stashEditor()
            let buffer = editorBuffers[id] ?? EditorBuffer()
            activeEditorTabID = id
            editorPath = buffer.path; editorText = buffer.text; editorOriginal = buffer.original
        }
        selectedTabID = id
        if tab.kind == .terminal {
            do { try terminal.start(directory: projectPath) } catch { self.error = error.localizedDescription }
        }
        if tab.kind == .computer { computer.refresh() }
    }
    func closeSelectedTab() {
        guard let selectedTab, tabCanClose(selectedTab) else { return }
        requestCloseTab(selectedTab.id)
    }
    func requestCloseTab(_ id: UUID) {
        do { try closeTab(id) } catch { self.error = error.localizedDescription }
    }
    func closeTab(_ id: UUID, fromAgent: Bool = false) throws {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { throw BobError.message("This tab is no longer open.") }
        let tab = openTabs[index]
        guard !tabIsDirty(tab) else { throw BobError.message("Save with ⌘S or discard this file's changes before closing its tab.") }
        guard !(fromAgent && tab.kind == .terminal && terminal.running) else { throw BobError.message("The terminal is running. Leave it open for the user to close.") }
        if tab.kind == .editor && !openTabs.contains(where: { $0.kind == .editor && $0.id != id }) {
            guard buffer(for: id)?.path != nil else { return }
            editorBuffers[id] = EditorBuffer()
            if activeEditorTabID == id { editorPath = nil; editorText = ""; editorOriginal = "" }
            if selectedTabID == id && openTabs.count > 1 {
                selectTab(openTabs[index + 1 < openTabs.count ? index + 1 : index - 1].id)
            }
            return
        }
        if tab.kind == .terminal { terminal.stop() }
        if tab.kind == .browser { browser.close(); configureBrowser() }
        if tab.kind == .computer { computer.cancel() }
        if tab.kind == .simulator { simulator.close() }
        openTabs.remove(at: index); editorBuffers[id] = nil
        if activeEditorTabID == id { activeEditorTabID = nil; editorPath = nil; editorText = ""; editorOriginal = "" }
        if selectedTabID == id {
            selectedTabID = nil
            if !openTabs.isEmpty { selectTab(openTabs[min(index, openTabs.count - 1)].id) }
        }
        if openTabs.isEmpty { selectedTabID = nil }
    }
    func buffer(for id: UUID) -> EditorBuffer? {
        if activeEditorTabID == id { return EditorBuffer(path: editorPath, text: editorText, original: editorOriginal) }
        return editorBuffers[id]
    }
    func tabIsDirty(_ tab: WorkspaceTab) -> Bool { tab.kind == .editor && buffer(for: tab.id)?.isDirty == true }
    func tabCanClose(_ tab: WorkspaceTab) -> Bool {
        tab.kind != .editor || buffer(for: tab.id)?.path != nil || openTabs.contains { $0.kind == .editor && $0.id != tab.id }
    }
    func tabTitle(_ tab: WorkspaceTab) -> String {
        if tab.kind == .editor, let path = buffer(for: tab.id)?.path { return URL(fileURLWithPath: path).lastPathComponent }
        if tab.kind == .browser, !browser.title.isEmpty { return browser.title }
        return tab.kind.rawValue
    }
    private func fileTab(at path: String) -> WorkspaceTab? { openTabs.first { $0.kind == .editor && buffer(for: $0.id)?.path == path } }
    private func stashEditor() {
        guard let id = activeEditorTabID else { return }
        editorBuffers[id] = EditorBuffer(path: editorPath, text: editorText, original: editorOriginal)
    }
    private func configureBrowser() {
        browser.onAgentUse = { [weak self] in self?.openPanel(.browser) }
    }
    func toggleEditorTerminal() {
        guard showWorkspacePanel else { return }
        if showEditorTerminal && selectedPanel == .editor {
            showEditorTerminal = false
            editorFocusRequest = UUID()
            return
        }
        do { try terminal.start(directory: projectPath) } catch {
            self.error = error.localizedDescription
            return
        }
        openPanel(.editor)
        showEditorTerminal = true
    }
    func startTerminal() {
        openPanel(.terminal)
    }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }
    func saveNow() {
        do { try persistence.save(WorkspaceSnapshot(sessions: sessions, selectedSessionID: selectedID, settings: settings)) }
        catch { self.error = "Could not save the workspace: \(error.localizedDescription)" }
    }
    func shutdown() { saveTask?.cancel(); projectTask?.cancel(); fileTree.reset(); commandPalette.stop(); stopAll(); terminal.stop(); browser.close(); computer.close(); simulator.close(); saveNow(); onOpenProject = nil }
}
