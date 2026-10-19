import Foundation

public enum ProjectInstructions {
    /// Root instructions are injected before the first model request. Deeper instructions
    /// are loaded for each file access; references are not followed outside the project.
    public static func load(files: WorkspaceFiles, path: String = ".", byteLimit: Int = 32_768) async throws -> String {
        let root = files.root
        let target = try await files.resolve(path)
        let relative = target.path == root.path ? "" : String(target.path.dropFirst(root.path.count + 1))
        var directories = [root]
        var current = root
        let components = relative.split(separator: "/")
        let isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        for part in isDirectory ? components[...] : components.dropLast() {
            current.appendPathComponent(String(part)); directories.append(current)
        }
        var result = "", remaining = byteLimit
        for directory in directories {
            let url = directory.appendingPathComponent("AGENTS.md")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try await files.read(url.path)
            guard text.utf8.count <= remaining else { throw BobError.message("Project AGENTS.md instructions exceed the \(byteLimit)-byte limit.") }
            remaining -= text.utf8.count
            result += "\n\nInstructions from \(url.path):\n\(text)"
        }
        return result
    }
}
