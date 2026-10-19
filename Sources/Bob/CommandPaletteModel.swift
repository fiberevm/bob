import Foundation
import Combine
import BobCore

enum CommandPaletteScope: String, CaseIterable, Identifiable {
    case all = "All", files = "Files", commands = "Commands"
    var id: Self { self }
}

struct CommandPaletteSelection {
    var selectedID: String?

    mutating func reconcile(_ ids: [String], reset: Bool = false) {
        if reset || !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
    }

    mutating func move(by offset: Int, in ids: [String]) {
        guard !ids.isEmpty else { selectedID = nil; return }
        guard let index = ids.firstIndex(where: { $0 == selectedID }) else {
            selectedID = offset < 0 ? ids.last : ids.first; return
        }
        selectedID = ids[((index + offset) % ids.count + ids.count) % ids.count]
    }
}

@MainActor final class CommandPaletteModel: ObservableObject {
    @Published private(set) var matches: [ProjectFile] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var generation = 0
    @Published private(set) var matchedQuery = ""
    private var index = ProjectFileSearch.Index()
    private var projectPath = ""
    private var indexID = UUID()
    private var indexTask: Task<Void, Never>?
    private var pendingPaths: Set<String> = []
    private var watcher: ProjectFileWatcher?
    private var watcherError: String?
    private var searchID = UUID()

    /// Project-owned work continues while the palette is closed.
    func start(projectPath: String) {
        guard self.projectPath != projectPath else { return }
        stop()
        self.projectPath = projectPath
        guard !projectPath.isEmpty else { return }
        let id = indexID
        do {
            watcher = try ProjectFileWatcher(root: projectPath) { [weak self] paths in
                guard let self, self.indexID == id else { return }
                self.enqueue(paths)
            }
        } catch { watcherError = error.localizedDescription }
        enqueue([""], immediately: true)
    }

    func load(projectPath: String) async {
        let reused = self.projectPath == projectPath
        start(projectPath: projectPath)
        // Fall back to a refresh on opening if macOS could not provide a live stream.
        if reused, watcher == nil, indexTask == nil { refresh() }
        // A cancelled sheet task must not cancel the shared project index.
        await indexTask?.value
    }

    func refresh() { if !projectPath.isEmpty { enqueue([""], immediately: true) } }

    func stop() {
        indexID = UUID(); searchID = UUID()
        indexTask?.cancel(); indexTask = nil
        watcher?.stop(); watcher = nil; watcherError = nil
        pendingPaths = []; projectPath = ""; index = ProjectFileSearch.Index()
        matches = []; matchedQuery = ""; error = nil
        isIndexing = false; isSearching = false; generation += 1
    }

    private func enqueue(_ paths: [String], immediately: Bool = false) {
        pendingPaths.formUnion(ProjectFileSearch.changedPaths(paths))
        guard !pendingPaths.isEmpty, indexTask == nil else { return }
        let id = indexID
        isIndexing = true
        indexTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            await self?.updateIndex(id: id)
        }
    }

    private func updateIndex(id: UUID) async {
        defer { if indexID == id { indexTask = nil; isIndexing = false } }
        while indexID == id, !Task.isCancelled, !pendingPaths.isEmpty {
            let paths = Array(pendingPaths); pendingPaths = []
            let snapshot = index, root = URL(fileURLWithPath: projectPath)
            let task = Task.detached(priority: .utility) { try snapshot.updating(root: root, paths: paths) }
            do {
                let updated = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                guard indexID == id, !Task.isCancelled else { return }
                index = updated; generation += 1; error = watcherError
            } catch is CancellationError { return }
            catch {
                guard indexID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if !pendingPaths.isEmpty {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }

    func search(_ query: String) async {
        guard !Task.isCancelled else { return }
        let id = UUID(); searchID = id
        isSearching = true
        defer { if searchID == id { isSearching = false } }
        do {
            // Coalesce fast typing, while keeping all filesystem and ranking work off the UI thread.
            try await Task.sleep(for: .milliseconds(45))
            let index = index, generation = generation
            let task = Task.detached(priority: .userInitiated) { try index.search(query) }
            let matches = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard searchID == id, self.generation == generation else { return }
            self.matches = matches; matchedQuery = query
        } catch {}
    }
}
