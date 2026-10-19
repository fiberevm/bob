import Foundation

public struct ProjectFile: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let name: String
    fileprivate let searchTitle: SearchText
    fileprivate let searchPath: SearchText
    public var directory: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }
    public init(relativePath: String) {
        self.relativePath = relativePath
        name = (relativePath as NSString).lastPathComponent
        searchTitle = SearchText(name)
        searchPath = SearchText(relativePath)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.relativePath == rhs.relativePath }
    public func hash(into hasher: inout Hasher) { hasher.combine(relativePath) }
}

/// Builds a filename index without reading file contents or following directory links.
/// Call from a background task; indexing and ranking both support cancellation.
public enum ProjectFileSearch {
    public static let maximumResults = 20

    /// An immutable, naturally sorted snapshot. Searches use its order to break score ties.
    public struct Index: Sendable {
        public let files: [ProjectFile]
        private let symbolicLinks: [String]

        public init(files: [ProjectFile] = []) {
            self.files = files.sorted(by: ProjectFileSearch.ordered)
            symbolicLinks = []
        }
        public init(root: URL) throws {
            try Task.checkCancellation()
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw BobError.message("The project folder is unavailable.")
            }
            let collected = try ProjectFileSearch.collect(root: root, path: "")
            files = collected.files.sorted(by: ProjectFileSearch.ordered)
            symbolicLinks = collected.symbolicLinks
        }

        public func search(_ query: String, limit: Int = maximumResults) throws -> [ProjectFile] {
            try ProjectFileSearch.search(query, in: files, limit: limit, presorted: true)
        }

        /// Reuse prepared entries outside changed files or subtrees; never follow directory links.
        public func updating(root: URL, paths: [String]) throws -> Index {
            try Task.checkCancellation()
            var paths = ProjectFileSearch.changedPaths(paths)
            guard !paths.isEmpty else { return self }
            if paths.contains("") { return try Index(root: root) }
            // An alias can become valid or invalid when its target changes elsewhere.
            // Retain even broken/hidden aliases so a restored target is discovered.
            paths = ProjectFileSearch.changedPaths(paths + symbolicLinks)
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            var replacements: [ProjectFile] = []
            var links: [String] = []
            for path in paths {
                let collected = try ProjectFileSearch.collect(root: root, path: path)
                replacements += collected.files; links += collected.symbolicLinks
            }
            replacements.sort(by: ProjectFileSearch.ordered)
            let changed = Set(paths)
            func unaffected(_ relativePath: String) throws -> Bool {
                try Task.checkCancellation()
                var path = relativePath[...]
                while true {
                    if changed.contains(String(path)) { return false }
                    guard let slash = path.lastIndex(of: "/") else { return true }
                    path = path[..<slash]
                }
            }
            let retained = try files.filter { try unaffected($0.relativePath) }
            links += try symbolicLinks.filter(unaffected)
            // Both inputs are sorted. Merge without sorting the whole project again.
            var merged: [ProjectFile] = []
            merged.reserveCapacity(retained.count + replacements.count)
            var next = 0
            for file in retained {
                try Task.checkCancellation()
                while next < replacements.count && ProjectFileSearch.ordered(replacements[next], file) {
                    merged.append(replacements[next]); next += 1
                }
                merged.append(file)
            }
            merged.append(contentsOf: replacements[next...])
            return Index(sortedFiles: merged, symbolicLinks: links)
        }

        private init(sortedFiles: [ProjectFile], symbolicLinks: [String]) {
            files = sortedFiles; self.symbolicLinks = symbolicLinks
        }
    }

    private static let excluded: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", ".DS_Store", ".next", ".nuxt",
        ".cache", ".venv", "__pycache__", ".gradle", "DerivedData"
    ]

    public static func index(root: URL) throws -> [ProjectFile] {
        try Index(root: root).files
    }

    /// Validate relative event paths and collapse nested changes before touching the filesystem.
    public static func changedPaths(_ paths: [String]) -> [String] {
        let valid = Set(paths.compactMap { path -> String? in
            let components = path.split(separator: "/")
            guard !path.hasPrefix("/"), !components.contains(where: { $0 == ".." || $0 == "." || excluded.contains(String($0)) }) else { return nil }
            return components.joined(separator: "/")
        })
        if valid.contains("") { return [""] }
        return valid.filter { path in
            var parent = path[...]
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                if valid.contains(String(parent)) { return false }
            }
            return true
        }.sorted()
    }

    private struct Collected {
        var files: [ProjectFile] = []
        var symbolicLinks: [String] = []
    }

    private static func collect(root: URL, path: String) throws -> Collected {
        try Task.checkCancellation()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let components = path.split(separator: "/").map(String.init)
        var start = root
        // A changed child beneath a directory link must not make incremental indexing follow it.
        for component in components.dropLast() {
            start.appendPathComponent(component)
            guard let values = try? start.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { return Collected() }
        }
        if let last = components.last { start.appendPathComponent(last) }
        guard let values = try? start.resourceValues(forKeys: keys) else { return Collected() }

        func file(_ url: URL, values: URLResourceValues, relativePath: String) -> ProjectFile? {
            if values.isSymbolicLink == true {
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(prefix),
                      !resolved.path.dropFirst(prefix.count).split(separator: "/").contains(".git"),
                      (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            } else if values.isRegularFile != true { return nil }
            return ProjectFile(relativePath: relativePath)
        }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Collected(files: file(start, values: values, relativePath: path).map { [$0] } ?? [],
                             symbolicLinks: values.isSymbolicLink == true ? [path] : [])
        }
        guard let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: Array(keys),
                                                            options: [], errorHandler: { _, _ in true }) else {
            throw BobError.message("Could not search the project folder.")
        }
        var collected = Collected()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if excluded.contains(url.lastPathComponent) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true, values.isDirectory == true { enumerator.skipDescendants() }
            // DirectoryEnumerator can return /private/var URLs for a /var root on macOS.
            // Its depth gives the relative components without relying on that spelling.
            let suffix = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let relativePath = path.isEmpty ? suffix : path + "/" + suffix
            if values.isSymbolicLink == true { collected.symbolicLinks.append(relativePath) }
            if let entry = file(url, values: values, relativePath: relativePath) { collected.files.append(entry) }
        }
        return collected
    }

    fileprivate static func ordered(_ lhs: ProjectFile, _ rhs: ProjectFile) -> Bool {
        let order = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
        return order == .orderedSame ? lhs.relativePath < rhs.relativePath : order == .orderedAscending
    }

    public static func search(_ query: String, in files: [ProjectFile], limit: Int = maximumResults) throws -> [ProjectFile] {
        try search(query, in: files, limit: limit, presorted: false)
    }

    private struct Match {
        let file: ProjectFile
        let score: Int
        let ordinal: Int
    }

    private static func search(_ query: String, in files: [ProjectFile], limit: Int, presorted: Bool) throws -> [ProjectFile] {
        try Task.checkCancellation()
        let limit = min(limit, maximumResults)
        guard limit > 0 else { return [] }
        let query = SearchQuery(query)
        guard !query.value.isEmpty else { return Array(files.prefix(limit)) }
        func better(_ lhs: Match, than rhs: Match) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if !presorted, lhs.file.relativePath != rhs.file.relativePath { return ordered(lhs.file, rhs.file) }
            return lhs.ordinal < rhs.ordinal
        }
        // A bounded heap with the worst retained result at its root.
        var best: [Match] = []
        best.reserveCapacity(limit)
        for (ordinal, file) in files.enumerated() {
            try Task.checkCancellation()
            guard let score = query.score(title: file.searchTitle, path: file.searchPath) else { continue }
            let candidate = Match(file: file, score: score, ordinal: ordinal)
            if best.count < limit {
                best.append(candidate)
                var child = best.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard better(best[parent], than: best[child]) else { break }
                    best.swapAt(parent, child); child = parent
                }
            } else if better(candidate, than: best[0]) {
                best[0] = candidate
                var parent = 0
                while parent * 2 + 1 < best.count {
                    var child = parent * 2 + 1
                    if child + 1 < best.count, better(best[child], than: best[child + 1]) { child += 1 }
                    guard better(best[parent], than: best[child]) else { break }
                    best.swapAt(parent, child); parent = child
                }
            }
        }
        return best.sorted { better($0, than: $1) }.map(\.file)
    }
}

/// Filename matches outrank directory matches; contiguous matches outrank abbreviations.
public enum CommandSearch {
    public static func score(_ query: String, title: String, path: String? = nil) -> Int? {
        SearchQuery(query).score(title: SearchText(title), path: path.map(SearchText.init))
    }
}

/// Keep compact bytes for ordinary paths and grapheme clusters for Unicode paths.
fileprivate struct SearchText: Sendable {
    let value: String
    let ascii: [UInt8]?
    let characters: [Character]?

    init(_ value: String) {
        self.value = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let bytes = Array(self.value.utf8)
        if bytes.allSatisfy({ $0 < 128 }) { ascii = bytes; characters = nil }
        else { ascii = nil; characters = Array(self.value) }
    }
}

fileprivate struct SearchQuery {
    struct Token {
        let value: String
        let ascii: [UInt8]?
        let characters: [Character]
        init(_ value: Substring) {
            self.value = String(value)
            let bytes = Array(value.utf8)
            ascii = bytes.allSatisfy { $0 < 128 } ? bytes : nil
            characters = Array(value)
        }
    }
    let value: String
    let tokens: [Token]

    init(_ query: String) {
        value = SearchText(query).value.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens = value.split(whereSeparator: \.isWhitespace).map(Token.init)
    }

    func score(title: SearchText, path: SearchText?) -> Int? {
        guard !value.isEmpty else { return 0 }
        if value == title.value { return 10_000 }
        var total = 0
        for token in tokens {
            if let score = Self.match(token, in: title) { total += 1_000 + score }
            else if let path, let score = Self.match(token, in: path) { total += score }
            else { return nil }
        }
        return total
    }

    private static func match(_ query: Token, in text: SearchText) -> Int? {
        if let haystack = text.ascii {
            guard let needle = query.ascii, needle.count <= haystack.count else { return nil }
            if haystack.starts(with: needle) { return haystack.count == needle.count ? 900 : 800 - min(haystack.count - needle.count, 100) }
            for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
                if haystack[start..<(start + needle.count)].elementsEqual(needle) { return 600 - min(start, 100) }
            }
            return fuzzy(needle, in: haystack) { $0 == 47 || $0 == 46 || $0 == 95 || $0 == 45 || $0 == 32 }
        }
        guard let haystack = text.characters else { return nil }
        if text.value == query.value { return 900 }
        if text.value.hasPrefix(query.value) { return 800 - min(haystack.count - query.characters.count, 100) }
        if let range = text.value.range(of: query.value) {
            return 600 - min(text.value.distance(from: text.value.startIndex, to: range.lowerBound), 100)
        }
        return fuzzy(query.characters, in: haystack) { "/._- ".contains($0) }
    }

    private static func fuzzy<Element: Equatable>(_ needle: [Element], in haystack: [Element], boundary: (Element) -> Bool) -> Int? {
        var next = 0, previous = -2, score = 0, first: Int?
        for (index, character) in haystack.enumerated() where character == needle[next] {
            if first == nil { first = index }
            if index == previous + 1 { score += 8 }
            if index == 0 || boundary(haystack[index - 1]) { score += 12 }
            previous = index; next += 1
            if next == needle.count { return 200 + score - min(index - (first ?? 0), 100) }
        }
        return nil
    }
}
