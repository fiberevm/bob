import Foundation
import BobCore

/// UTF-16 offsets match TextKit, including emoji and files with Windows line endings.
struct SourceLineMap {
    let starts: [Int]
    var count: Int { starts.count }

    init(_ text: String) {
        var starts = [0], previousWasCR = false
        for (offset, unit) in text.utf16.enumerated() {
            if unit == 10 && previousWasCR { starts[starts.count - 1] = offset + 1 }
            else if unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 { starts.append(offset + 1) }
            previousWasCR = unit == 13
        }
        self.starts = starts
    }

    func line(at offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
}

enum SourceLanguage: Sendable {
    case swift, javascript, python, rust, go, c, shell, json, yaml, markdown, markup, css, plain

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension.lowercased() {
        case "swift": self = .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": self = .javascript
        case "py", "pyw": self = .python
        case "rs": self = .rust
        case "go": self = .go
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "cs", "kt", "kts": self = .c
        case "sh", "bash", "zsh", "fish": self = .shell
        case "json", "jsonc": self = .json
        case "yaml", "yml", "toml": self = .yaml
        case "md", "markdown": self = .markdown
        case "html", "htm", "xml", "plist", "svg": self = .markup
        case "css", "scss", "sass", "less": self = .css
        default: self = ["Makefile", "Dockerfile", ".gitignore"].contains(url.lastPathComponent) ? .shell : .plain
        }
    }
}

enum SyntaxKind: String, CaseIterable, Sendable {
    case comment, string, number, keyword, type, attribute
}

struct SyntaxSpan: Equatable, Sendable {
    let kind: SyntaxKind
    let range: NSRange
}

/// A lightweight lexical pass; strings and comments win over tokens inside them.
/// Runs off the main thread and never changes the document or its undo history.
enum SyntaxHighlighter {
    static func diffSpans(in diff: FileDiff, before: String, after: String, language: SourceLanguage) -> [[SyntaxSpan]] {
        guard language != .plain else { return Array(repeating: [], count: diff.lines.count) }
        let old = spansByDiffLine(in: before, language: language)
        let new = spansByDiffLine(in: after, language: language)
        return diff.lines.map { line in
            switch line.kind {
            case .removed: return line.oldNumber.flatMap { old[$0] } ?? []
            case .added, .context: return line.newNumber.flatMap { new[$0] } ?? []
            case .hunk, .note: return []
            }
        }
    }

    private static func spansByDiffLine(in text: String, language: SourceLanguage) -> [Int: [SyntaxSpan]] {
        // Diff counts LF-delimited lines. Tokenize the whole revision so omitted
        // context still determines multiline strings and comments correctly.
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 10 { starts.append(offset + 1) }
        let source = text as NSString, length = source.length
        var result: [Int: [SyntaxSpan]] = [:], firstLine = 0
        for span in spans(in: text, language: language) {
            if Task.isCancelled { break }
            while firstLine + 1 < starts.count && starts[firstLine + 1] <= span.range.location { firstLine += 1 }
            var line = firstLine
            while line < starts.count && starts[line] < NSMaxRange(span.range) {
                var end = line + 1 < starts.count ? starts[line + 1] - 1 : length
                if end > starts[line] && source.character(at: end - 1) == 13 { end -= 1 }
                let intersection = NSIntersectionRange(span.range, NSRange(location: starts[line], length: end - starts[line]))
                if intersection.length > 0 {
                    result[line + 1, default: []].append(SyntaxSpan(kind: span.kind, range: NSRange(location: intersection.location - starts[line], length: intersection.length)))
                }
                line += 1
            }
        }
        return result
    }

    static func spans(in text: String, language: SourceLanguage) -> [SyntaxSpan] {
        guard language != .plain, !text.isEmpty else { return [] }
        let quoted = #""(?:\\[\s\S]|[^"\\\r\n])*(?:"|$)|'(?:\\[\s\S]|[^'\\\r\n])*(?:'|$)"#
        let cComment = #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)"#
        var rules: [(SyntaxKind, String)] = []
        var keywords = ""
        switch language {
        case .markdown:
            rules = [(.comment, #"<!--[\s\S]*?(?:-->|\z)"#),
                     (.string, #"(?ms:^```[^\n]*\n.*?(?:^```[^\n]*$|\z))|`[^`\r\n]+`"#),
                     (.keyword, #"^ {0,3}#{1,6}[^\r\n]*"#),
                     (.attribute, #"\[[^\]\r\n]+\]\([^\)\r\n]+\)|\*\*[^*\r\n]+\*\*"#)]
        case .markup:
            rules = [(.comment, #"<!--[\s\S]*?(?:-->|\z)"#), (.string, quoted),
                     (.keyword, #"</?[\w:.-]+|/?>"#), (.attribute, #"[\w:-]+(?=\s*=)"#)]
        case .swift:
            rules = [(.comment, cComment), (.string, #"[#]*"""[\s\S]*?(?:"""[#]*|\z)|[#]*"(?:\\[\s\S]|[^"\\\r\n])*(?:"[#]*|$)"#)]
            keywords = "actor any as associatedtype async await borrowing break case catch class consuming continue convenience copy default defer deinit didSet distributed do dynamic each else enum extension fallthrough false fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let macro mutating nil nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throws throw true try typealias unowned var weak where while willSet"
        case .python:
            rules = [(.comment, #"[#][^\r\n]*"#), (.string, #""""[\s\S]*?(?:"""|\z)|'''[\s\S]*?(?:'''|\z)|"# + quoted)]
            keywords = "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"
        case .shell, .yaml:
            rules = [(.comment, #"[#][^\r\n]*"#), (.string, quoted), (.attribute, #"\$\{?\w+\}?|^[\w.-]+(?=\s*:)"#)]
            keywords = "if then else elif fi for in do done case esac function export local return while until true false null yes no"
        case .json:
            rules = [(.comment, cComment), (.string, quoted)]
            keywords = "true false null"
        case .javascript:
            rules = [(.comment, cComment), (.string, #"`(?:\\[\s\S]|[^`\\])*(?:`|\z)|"# + quoted)]
            keywords = "abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let namespace new null of private protected public readonly return satisfies set static super switch this throw true try type typeof undefined var void while with yield"
        case .rust:
            rules = [(.comment, cComment), (.string, quoted)]
            keywords = "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
        case .go:
            rules = [(.comment, cComment), (.string, #"`[^`]*(?:`|\z)|"# + quoted)]
            keywords = "break case chan const continue default defer else fallthrough for func go goto if import interface map nil package range return select struct switch type var true false"
        case .c, .css:
            rules = [(.comment, cComment), (.string, quoted)]
            keywords = "auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false final float for friend if import inline int interface long namespace new nullptr null operator override package private protected public register return short signed sizeof static struct super switch template this throw true try typedef typename union unsigned using virtual void volatile while"
        case .plain: return []
        }
        if !keywords.isEmpty { rules.append((.keyword, #"\b(?:"# + keywords.split(separator: " ").joined(separator: "|") + #")\b"#)) }
        if language != .markdown && language != .markup {
            rules.append((.number, #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)(?!\w)"#))
            if !rules.contains(where: { $0.0 == .attribute }) {
                rules.append((.attribute, #"@[\w.]+|[#][A-Za-z_]\w*"#))
            }
            rules.append((.type, #"\b[A-Z][A-Za-z_0-9]*\b"#))
        }
        let pattern = rules.map { "(?<\($0.0.rawValue)>\($0.1))" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var spans: [SyntaxSpan] = []
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match else { return }
            for (kind, _) in rules {
                let range = match.range(withName: kind.rawValue)
                if range.location != NSNotFound { spans.append(SyntaxSpan(kind: kind, range: range)); break }
            }
        }
        return spans
    }
}
