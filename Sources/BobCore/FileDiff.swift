import Foundation

public enum FileChangeKind: String, Equatable, Sendable {
    case modified, added, deleted, renamed, untracked, conflicted

    public var badge: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }
    public var label: String { rawValue.capitalized }
}

public struct GitFileChange: Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let kind: FileChangeKind

    /// Porcelain -z keeps spaces, quotes, newlines and rename paths unambiguous.
    public static func parse(_ output: String, repository: URL, project: URL) -> [GitFileChange] {
        let repository = repository.standardizedFileURL.resolvingSymlinksInPath()
        let project = project.standardizedFileURL.resolvingSymlinksInPath()
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        var changes: [GitFileChange] = [], index = 0
        while index < records.count {
            let record = String(records[index]); index += 1
            guard record.count >= 4 else { continue }
            let code = String(record.prefix(2))
            let path = repository.appendingPathComponent(String(record.dropFirst(3))).path
            var original: String?
            if code.contains("R") || code.contains("C"), index < records.count {
                original = repository.appendingPathComponent(String(records[index])).path
                index += 1
            }
            guard path.hasPrefix(project.path + "/") else { continue }
            let kind: FileChangeKind
            if code == "??" { kind = .untracked }
            else if code.contains("U") || ["AA", "DD"].contains(code) { kind = .conflicted }
            else if code.contains("D") { kind = .deleted }
            else if code.contains("R") { kind = .renamed }
            else if code.contains("A") || code.contains("C") { kind = .added }
            else { kind = .modified }
            changes.append(GitFileChange(path: path, originalPath: original, kind: kind))
        }
        return changes
    }
}

public struct FileDiff: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case context, added, removed, hunk, note }
        public let kind: Kind
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?
    }
    public let lines: [Line]
    public var addedCount: Int { lines.filter { $0.kind == .added }.count }
    public var removedCount: Int { lines.filter { $0.kind == .removed }.count }

    public static func compare(before: String, after: String) async throws -> FileDiff {
        guard before != after else { return FileDiff(lines: []) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bob-diff-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("before"), new = directory.appendingPathComponent("after")
        try Data(before.utf8).write(to: old)
        try Data(after.utf8).write(to: new)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/diff"), arguments: ["-u", "-L", "Before", "-L", "Current", old.path, new.path])
        guard result.status == 0 || result.status == 1 else { throw BobError.message("Could not compare this file. \(result.error)") }
        guard !result.output.hasPrefix("[Earlier output truncated]") else { throw BobError.message("This diff is too large to display. Open Edit to view the file.") }
        return parse(result.output)
    }

    private static func parse(_ patch: String) -> FileDiff {
        let hunk = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        var old = 0, new = 0, lines: [Line] = []
        for raw in patch.components(separatedBy: "\n").dropFirst(2) where !raw.isEmpty {
            let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let match = hunk.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                old = Int((text as NSString).substring(with: match.range(at: 1))) ?? 0
                new = Int((text as NSString).substring(with: match.range(at: 2))) ?? 0
                lines.append(Line(kind: .hunk, text: text, oldNumber: nil, newNumber: nil))
            } else {
                switch text.first {
                case "+": lines.append(Line(kind: .added, text: String(text.dropFirst()), oldNumber: nil, newNumber: new)); new += 1
                case "-": lines.append(Line(kind: .removed, text: String(text.dropFirst()), oldNumber: old, newNumber: nil)); old += 1
                case " ": lines.append(Line(kind: .context, text: String(text.dropFirst()), oldNumber: old, newNumber: new)); old += 1; new += 1
                default: lines.append(Line(kind: .note, text: text, oldNumber: nil, newNumber: nil))
                }
            }
        }
        return FileDiff(lines: lines)
    }
}
