import Foundation
import Combine
import BobCore

struct FileTreeRow: Identifiable, Equatable {
    var id: String { entry.path }
    let entry: FileEntry
    let depth: Int
}

@MainActor final class FileTree: ObservableObject {
    @Published private(set) var rows: [FileTreeRow] = []
    @Published private(set) var expandedPaths: Set<String> = []
    @Published private(set) var loadingPaths: Set<String> = []
    @Published private(set) var isRefreshing = false
    private var roots: [FileEntry] = []
    private var children: [String: [FileEntry]] = [:]
    private var files: WorkspaceFiles?
    private var generation = UUID()
    private var rootPath = ""
    private var changedPaths: Set<String> = []

    func reset(files: WorkspaceFiles? = nil) {
        generation = UUID(); self.files = files
        roots = []; children = [:]; expandedPaths = []; loadingPaths = []; rows = []
        isRefreshing = false
        rootPath = ""; changedPaths = []
    }

    func setChangedPaths(_ paths: Set<String>) {
        changedPaths = paths
        updateRows()
    }

    func toggleFolder(_ entry: FileEntry) async throws {
        guard entry.isDirectory, let files, !isRefreshing else { return }
        let path = entry.path
        if expandedPaths.contains(path) {
            expandedPaths.remove(path); updateRows(); return
        }
        expandedPaths.insert(path)
        updateRows()
        try await loadExpandedBranch(path, files: files, generation: generation)
    }

    func refresh() async throws {
        guard let files else { return }
        // Invalidate pending folder reads before rebuilding the visible branches.
        generation = UUID()
        let current = generation, expanded = expandedPaths
        loadingPaths = []; isRefreshing = true
        defer { if generation == current { isRefreshing = false } }
        let rootPath = await files.root.path
        self.rootPath = rootPath
        let roots = try await listChildren(rootPath, files: files)
        var children: [String: [FileEntry]] = [:]
        var pending = entries(in: rootPath, existing: roots).filter { $0.isDirectory && expanded.contains($0.path) }
        while let folder = pending.popLast() {
            try Task.checkCancellation()
            guard generation == current else { return }
            let entries = try await listChildren(folder.path, files: files)
            children[folder.path] = entries
            pending += self.entries(in: folder.path, existing: entries).filter { $0.isDirectory && expanded.contains($0.path) }
        }
        guard generation == current, !Task.isCancelled else { return }
        self.roots = roots; self.children = children
        // Drop expansion state for removed entries whose parent was refreshed.
        expandedPaths = expanded.filter { path in
            var folder = URL(fileURLWithPath: path)
            while folder.path != rootPath && folder.path != "/" {
                let parent = folder.deletingLastPathComponent()
                if let entries = parent.path == rootPath ? roots : children[parent.path],
                   !self.entries(in: parent.path, existing: entries).contains(where: { $0.path == folder.path && $0.isDirectory }) { return false }
                folder = parent
            }
            return folder.path == rootPath
        }
        updateRows()
    }

    func reveal(_ entry: FileEntry) async throws {
        guard let files else { return }
        let root = await files.root.path
        var folder = URL(fileURLWithPath: entry.path)
        if !entry.isDirectory { folder.deleteLastPathComponent() }
        while folder.path != root && folder.path.hasPrefix(root + "/") {
            expandedPaths.insert(folder.path)
            folder.deleteLastPathComponent()
        }
        try await refresh()
    }

    func remapExpandedPaths(from source: String, to destination: String) {
        expandedPaths = Set(expandedPaths.map { WorkspaceFiles.remap($0, from: source, to: destination) })
    }

    func removeExpandedPaths(under path: String) {
        expandedPaths = expandedPaths.filter { !WorkspaceFiles.contains($0, in: path) }
    }

    private func loadExpandedBranch(_ path: String, files: WorkspaceFiles, generation current: UUID) async throws {
        guard generation == current, expandedPaths.contains(path), !loadingPaths.contains(path), !Task.isCancelled else { return }
        if children[path] == nil {
            loadingPaths.insert(path)
            defer { if generation == current { loadingPaths.remove(path) } }
            do {
                let entries = try await listChildren(path, files: files)
                guard generation == current, !Task.isCancelled else { return }
                children[path] = entries
                updateRows()
            } catch {
                guard generation == current else { return }
                expandedPaths.remove(path); updateRows()
                throw error
            }
        }
        for child in children[path] ?? [] where child.isDirectory && expandedPaths.contains(child.path) {
            guard generation == current, expandedPaths.contains(path) else { return }
            try await loadExpandedBranch(child.path, files: files, generation: current)
        }
    }

    private func listChildren(_ path: String, files: WorkspaceFiles) async throws -> [FileEntry] {
        // Keep the displayed ancestry when a directory resolves through an in-project symlink.
        do {
            return try await files.list(path).map {
                FileEntry(path: URL(fileURLWithPath: path).appendingPathComponent($0.name).path, name: $0.name, isDirectory: $0.isDirectory)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile && changedPaths.contains(where: { $0.hasPrefix(path + "/") }) {
            return []
        }
    }

    private func entries(in directory: String, existing: [FileEntry]) -> [FileEntry] {
        guard !directory.isEmpty else { return existing }
        var entries = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })
        for path in changedPaths where path.hasPrefix(directory + "/") {
            let components = path.dropFirst(directory.count + 1).split(separator: "/")
            guard let name = components.first.map(String.init), entries[name] == nil,
                  ![".git", ".build", "node_modules", ".DS_Store", ".swiftpm"].contains(name) else { continue }
            entries[name] = FileEntry(path: URL(fileURLWithPath: directory).appendingPathComponent(name).path, name: name, isDirectory: components.count > 1)
        }
        return entries.values.sorted { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }
    }

    private func updateRows() {
        var result: [FileTreeRow] = []
        var pending = entries(in: rootPath, existing: roots).reversed().map { FileTreeRow(entry: $0, depth: 0) }
        while let row = pending.popLast() {
            result.append(row)
            if row.entry.isDirectory && expandedPaths.contains(row.id) {
                pending += entries(in: row.id, existing: children[row.id] ?? []).reversed().map { FileTreeRow(entry: $0, depth: row.depth + 1) }
            }
        }
        rows = result
    }
}
