import Foundation
import CryptoKit

public struct FileEntry: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public init(path: String, name: String, isDirectory: Bool) { self.path = path; self.name = name; self.isDirectory = isDirectory }
}

public struct FileCheckpoint: Codable, Identifiable {
    public var id = UUID()
    public let path: String
    public let before: Data?
    public let afterHash: String
    public let date: Date
}

public enum FileExpectation: Equatable, Sendable {
    case absent
    case contents(Data)
}

public typealias WorkspaceTrashHandler = @Sendable (URL) throws -> Void

public actor WorkspaceFiles {
    public static let systemTrash: WorkspaceTrashHandler = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    public let root: URL
    private let checkpointURL: URL
    private var checkpoints: [FileCheckpoint] = []
    private let trashItem: WorkspaceTrashHandler
    public init(root: URL, checkpointDirectory: URL, trashItem: @escaping WorkspaceTrashHandler = WorkspaceFiles.systemTrash) {
        self.trashItem = trashItem
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let hash = SHA256.hash(data: Data(self.root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        checkpointURL = checkpointDirectory.appendingPathComponent(hash + ".json")
        if let data = try? Data(contentsOf: checkpointURL) { checkpoints = (try? JSONDecoder().decode([FileCheckpoint].self, from: data)) ?? [] }
    }
    public func resolve(_ relative: String) throws -> URL {
        let proposed = relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : root.appendingPathComponent(relative)
        // Foundation doesn't resolve ancestor symlinks when the final path doesn't exist.
        // Resolve the nearest existing ancestor, then append the new path components.
        var ancestor = proposed.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                throw BobError.message("The path contains a dangling symlink.")
            }
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { throw BobError.message("The path is outside the selected project.") }
        let components = resolved.path.dropFirst(root.path.count).split(separator: "/")
        guard !components.contains(".git") else { throw BobError.message("Direct access to Git metadata is disabled. Use Git commands for repository operations.") }
        return resolved
    }
    public func list(_ path: String = ".") throws -> [FileEntry] {
        let url = try resolve(path)
        let excluded: Set<String> = [".git", ".build", "node_modules", ".DS_Store", ".swiftpm"]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            .filter { !excluded.contains($0.lastPathComponent) }
            .prefix(2000).map { entry in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let directory = values?.isDirectory == true || (values?.isSymbolicLink == true && (try? entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
                return FileEntry(path: entry.path, name: entry.lastPathComponent, isDirectory: directory)
            }
            .sorted { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }
    }
    public func read(_ path: String) throws -> String {
        let url = try resolve(path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw BobError.message("This file exceeds the initial editor's 2 MB limit.") }
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw BobError.message("This file is not UTF-8 text.") }
        return text
    }
    public static func validateItemName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains(where: { "/:\0\n\r".contains($0) }) else {
            throw BobError.message("Enter a name without slashes, colons, or line breaks.")
        }
        guard name.lowercased() != ".git" else { throw BobError.message("Git metadata cannot be changed from the file tree.") }
    }
    public func createItem(named name: String, in directory: String, isDirectory: Bool) throws -> FileEntry {
        try Task.checkCancellation()
        try Self.validateItemName(name)
        let parent = try resolve(directory)
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw BobError.message("Choose a folder for the new item.")
        }
        let destination = parent.appendingPathComponent(name)
        guard !itemExists(destination) else { throw BobError.message("An item named “\(name)” already exists in this folder.") }
        if isDirectory { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
        else { try Data().write(to: destination, options: .withoutOverwriting) }
        return FileEntry(path: destination.path, name: name, isDirectory: isDirectory)
    }
    /// Resolve the parent, preserving a final symlink so Rename and Trash act on the link itself.
    public func fileTreeItemPath(_ path: String) throws -> String {
        let url = try fileTreeItemURL(path)
        _ = try FileManager.default.attributesOfItem(atPath: url.path)
        return url.path
    }
    public func renameItem(_ path: String, to name: String) throws -> (from: String, to: String) {
        try Task.checkCancellation()
        try Self.validateItemName(name)
        let source = try fileTreeItemURL(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        if source.path == destination.path { return (source.path, destination.path) }
        if itemExists(destination) {
            let other = try FileManager.default.attributesOfItem(atPath: destination.path)
            let caseSensitive = try source.deletingLastPathComponent().resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true
            guard !caseSensitive, source.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame,
                  (attributes[.systemFileNumber] as? NSNumber) == (other[.systemFileNumber] as? NSNumber) else {
                throw BobError.message("An item named “\(name)” already exists in this folder.")
            }
        }
        let updated = checkpoints.map { checkpoint -> FileCheckpoint in
            let path = Self.remap(checkpoint.path, from: source.path, to: destination.path)
            return FileCheckpoint(id: checkpoint.id, path: path, before: checkpoint.before, afterHash: checkpoint.afterHash, date: checkpoint.date)
        }
        try withUpdatedCheckpoints(updated) { try FileManager.default.moveItem(at: source, to: destination) }
        return (source.path, destination.path)
    }
    /// Called only after the file tree's explicit confirmation. Never fall back to permanent removal.
    public func trashItemAtPath(_ path: String) throws -> String {
        try Task.checkCancellation()
        let source = try fileTreeItemURL(path)
        _ = try FileManager.default.attributesOfItem(atPath: source.path)
        let updated = checkpoints.filter { !Self.contains($0.path, in: source.path) }
        try withUpdatedCheckpoints(updated) { try trashItem(source) }
        return source.path
    }
    public static func contains(_ path: String, in directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }
    public static func remap(_ path: String, from source: String, to destination: String) -> String {
        contains(path, in: source) ? destination + path.dropFirst(source.count) : path
    }
    private func fileTreeItemURL(_ path: String) throws -> URL {
        let proposed = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        guard proposed.path != root.path else { throw BobError.message("The project folder cannot be renamed or deleted.") }
        let parent = try resolve(proposed.deletingLastPathComponent().path)
        guard proposed.lastPathComponent.lowercased() != ".git" else { throw BobError.message("Git metadata cannot be changed from the file tree.") }
        return parent.appendingPathComponent(proposed.lastPathComponent)
    }
    private func itemExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
    private func withUpdatedCheckpoints(_ updated: [FileCheckpoint], operation: () throws -> Void) throws {
        guard updated.map(\.path) != checkpoints.map(\.path) else { try operation(); return }
        let previous = checkpoints
        checkpoints = updated
        do { try persist(); try operation() }
        catch { checkpoints = previous; try? persist(); throw error }
    }
    public func expectation(_ path: String) throws -> FileExpectation {
        let url = try resolve(path)
        do {
            // Read errors must not turn into permission to replace a file.
            let text = try read(path)
            return .contents(Data(text.utf8))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw error }
            return .absent
        }
    }
    public func write(_ path: String, text: String, expected: String? = nil) throws {
        try write(path, text: text, expectation: expected.map { .contents(Data($0.utf8)) })
    }
    public func write(_ path: String, text: String, expectation: FileExpectation?) throws {
        try Task.checkCancellation()
        let url = try resolve(path)
        guard url.path != root.path else { throw BobError.message("Choose a file inside the project.") }
        let manager = FileManager.default
        let before = manager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if let expectation {
            let matches: Bool
            switch expectation {
            case .absent: matches = before == nil
            case .contents(let data): matches = before == data
            }
            guard matches else { throw BobError.message("The file changed on disk. Read it again before saving.") }
        }
        let data = Data(text.utf8)
        guard data.count <= 2 * 1024 * 1024, (before?.count ?? 0) <= 2 * 1024 * 1024 else { throw BobError.message("Checkpointed writes are limited to 2 MB per file.") }
        // Save the checkpoint before modifying the file so a failed persistence write cannot lose undo.
        let checkpoint = FileCheckpoint(path: url.path, before: before, afterHash: Self.hash(data), date: Date())
        let previous = checkpoints
        checkpoints.append(checkpoint)
        while checkpoints.count > 20 || checkpoints.reduce(0, { $0 + ($1.before?.count ?? 0) }) > 20 * 1024 * 1024 { checkpoints.removeFirst() }
        do {
            try persist()
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { checkpoints = previous; try? persist(); throw error }
    }
    public func history() -> [FileCheckpoint] { checkpoints.reversed() }
    public func undo() throws -> String {
        guard let checkpoint = checkpoints.last else { throw BobError.message("There are no Bob file edits to undo.") }
        let url = try resolve(checkpoint.path)
        let current = try Data(contentsOf: url)
        guard Self.hash(current) == checkpoint.afterHash else { throw BobError.message("The file changed after this checkpoint. Undo would overwrite newer work.") }
        if let before = checkpoint.before { try before.write(to: url, options: .atomic) }
        else { try FileManager.default.removeItem(at: url) }
        checkpoints.removeLast(); try persist()
        return url.lastPathComponent
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoints).write(to: checkpointURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum WorkspaceTools {
    public static var definitions: [ToolDefinition] {
        func schema(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }
        let path = ["type": "string", "description": "Path relative to the project root."]
        return [
            ToolDefinition(name: "list_files", description: "List the immediate children of a project directory. Hidden build and dependency folders are excluded.", parameters: schema(["path": path], ["path"])),
            ToolDefinition(name: "read_file", description: "Read a UTF-8 file inside the project, up to 2 MB.", parameters: schema(["path": path], ["path"])),
            ToolDefinition(name: "write_file", description: "Write the full UTF-8 content of a project file. Bob creates an undo checkpoint. Requires approval only when Clef assesses high or critical risk.", parameters: schema(["path": path, "content": ["type": "string"]], ["path", "content"])),
            ToolDefinition(name: "run_command", description: "Run a shell command directly on this Mac, starting in the project directory, with the user's normal home directory, tool path, file permissions and network access. Low- and medium-risk commands run automatically. High and critical risk require confirmation. Commands have a 60-second limit.", parameters: schema(["command": ["type": "string"]], ["command"]))
        ]
    }
}

public struct GitState {
    public var branch = "No repository"
    public var status = ""
    public var diff = ""
    public var worktrees: [String] = []
    public var isRepository = false
    public var repositoryRoot: String?
    public var revision: String?
    public var changes: [GitFileChange] = []
    public init() {}
}

public enum GitService {
    private static let executable = URL(fileURLWithPath: "/usr/bin/git")
    public static func inspect(directory: URL) async throws -> GitState {
        let result = try await ProcessRunner.run(executable, arguments: ["status", "--short", "--branch"], directory: directory)
        guard result.status == 0 else { return GitState() }
        var state = GitState(); state.isRepository = true
        let lines = result.output.components(separatedBy: "\n")
        state.branch = String((lines.first ?? "## HEAD").dropFirst(3)).components(separatedBy: "...").first ?? "HEAD"
        state.status = lines.dropFirst().joined(separator: "\n")
        let root = try await ProcessRunner.run(executable, arguments: ["rev-parse", "--show-toplevel"], directory: directory)
        guard root.status == 0 else { return state }
        let repository = URL(fileURLWithPath: root.output.trimmingCharacters(in: .newlines)).standardizedFileURL.resolvingSymlinksInPath()
        state.repositoryRoot = repository.path
        let revision = try await ProcessRunner.run(executable, arguments: ["rev-parse", "--verify", "HEAD"], directory: directory)
        if revision.status == 0 { state.revision = revision.output.trimmingCharacters(in: .newlines) }
        let changes = try await ProcessRunner.run(executable, arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], directory: directory)
        guard changes.status == 0, !changes.output.hasPrefix("[Earlier output truncated]") else { throw BobError.message("Could not load the project's changed files. \(changes.error)") }
        state.changes = GitFileChange.parse(changes.output, repository: repository, project: directory)
        let diff = try await ProcessRunner.run(executable, arguments: ["diff", "--no-ext-diff", "--no-color", "HEAD", "--"], directory: directory)
        state.diff = String(diff.output.prefix(200_000))
        let trees = try await ProcessRunner.run(executable, arguments: ["worktree", "list", "--porcelain"], directory: directory)
        state.worktrees = trees.output.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
        return state
    }
    public static func originalText(path: String, repository: URL, revision: String) async throws -> String? {
        guard path.hasPrefix(repository.path + "/") else { return nil }
        let relative = String(path.dropFirst(repository.path.count + 1))
        let result = try await ProcessRunner.run(executable, arguments: ["show", "\(revision):\(relative)"], directory: repository)
        guard result.status == 0 else { return nil }
        guard !result.output.hasPrefix("[Earlier output truncated]"), !result.output.contains("\0") else {
            throw BobError.message("The original file is too large or is not text. Open Edit to view the current file.")
        }
        return result.output
    }
    public static func createWorktree(directory: URL, destination: URL, branch: String) async throws {
        let check = try await ProcessRunner.run(executable, arguments: ["check-ref-format", "--branch", branch], directory: directory)
        guard check.status == 0, !branch.hasPrefix("-") else { throw BobError.message("Enter a valid new branch name.") }
        let result = try await ProcessRunner.run(executable, arguments: ["worktree", "add", "-b", branch, destination.path], directory: directory, timeout: 60)
        guard result.status == 0 else { throw BobError.message(result.error) }
    }
}
