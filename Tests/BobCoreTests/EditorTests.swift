import AppKit
import XCTest
@testable import Bob
@testable import BobCore

final class SyntaxHighlightingTests: XCTestCase {
    private func tokens(_ source: String, _ language: SourceLanguage) -> [(SyntaxKind, String)] {
        SyntaxHighlighter.spans(in: source, language: language).map { ($0.kind, (source as NSString).substring(with: $0.range)) }
    }

    func testSwiftStringsAndCommentsProtectTheirContents() {
        let source = "let title: String = \"🙂 class // 42\"\n// return true\nlet count = 42\n/* let hidden = 7 */"
        let result = tokens(source, .swift)
        XCTAssertEqual(result.filter { $0.0 == .keyword }.map(\.1), ["let", "let"])
        XCTAssertEqual(result.filter { $0.0 == .string }.map(\.1), ["\"🙂 class // 42\""])
        XCTAssertEqual(result.filter { $0.0 == .comment }.count, 2)
        XCTAssertEqual(result.filter { $0.0 == .number }.map(\.1), ["42"])
        XCTAssertEqual(result.filter { $0.0 == .type }.map(\.1), ["String"])
    }

    func testMultilineStringsAndLanguageSelection() {
        let source = "let text = \"\"\"\nclass false 42\n\"\"\"\nreturn text"
        XCTAssertEqual(tokens(source, .swift).filter { $0.0 == .keyword }.map(\.1), ["let", "return"])
        XCTAssertEqual(SourceLanguage(path: "Editor.swift"), .swift)
        XCTAssertEqual(SourceLanguage(path: "view.TSX"), .javascript)
        XCTAssertEqual(SourceLanguage(path: "README.md"), .markdown)
        XCTAssertTrue(tokens("let text = 42", .plain).isEmpty)
    }

    func testLanguageRulesProduceTokens() {
        let fixtures: [(SourceLanguage, String)] = [
            (.javascript, "const text = `return 1`; // comment"), (.python, "def run():\n    return True # comment"),
            (.rust, "pub fn run() { let count = 1; }"), (.go, "package main\nfunc run() { return }"),
            (.c, "const int count = 1;"), (.shell, "export NAME=\"value\" # comment"),
            (.json, "{\"count\": 42, \"valid\": true}"), (.yaml, "enabled: true # comment"),
            (.markdown, "# Heading\n`let a = 42`"), (.markup, "<div class=\"name\">text</div>"),
            (.css, "/* comment */ .item { color: \"red\"; }")
        ]
        for (language, source) in fixtures {
            XCTAssertFalse(SyntaxHighlighter.spans(in: source, language: language).isEmpty, "Missing tokens for \(language)")
        }
    }

    func testLineMapHandlesUnicodeCRLFAndTrailingEmptyLines() {
        let map = SourceLineMap("🙂\r\nsecond\rthird\n")
        XCTAssertEqual(map.starts, [0, 4, 11, 17])
        XCTAssertEqual(map.count, 4)
        XCTAssertEqual(map.line(at: 3), 0)
        XCTAssertEqual(map.line(at: 4), 1)
        XCTAssertEqual(map.line(at: 17), 3)
        XCTAssertEqual(SourceLineMap("").starts, [0])
        XCTAssertEqual(SourceLineMap("\n\n").count, 3)
        XCTAssertEqual(SourceLineMap("a\u{2028}b\u{2029}").starts, [0, 2, 4])
    }

    func testDiffHighlightingUsesEachRevisionIncludingOmittedMultilineContext() async throws {
        let middle = String(repeating: "filler\n", count: 10)
        let before = "/*\n" + middle + "let old = 1\n*/\n"
        let after = "// intro\n" + middle + "let current = 2\n*/\n"
        let diff = try await FileDiff.compare(before: before, after: after)
        let spans = SyntaxHighlighter.diffSpans(in: diff, before: before, after: after, language: .swift)
        let removed = try XCTUnwrap(diff.lines.firstIndex { $0.kind == .removed && $0.text == "let old = 1" })
        let added = try XCTUnwrap(diff.lines.firstIndex { $0.kind == .added && $0.text == "let current = 2" })
        XCTAssertEqual(spans[removed].map(\.kind), [.comment])
        XCTAssertEqual(spans[added].map(\.kind), [.keyword, .number])
        for (line, highlights) in zip(diff.lines, spans) where line.kind == .hunk { XCTAssertTrue(highlights.isEmpty) }
    }

    func testDiffHighlightingPreservesUnicodeRangesAndWindowsLineEndings() async throws {
        let before = "let greeting = \"🙂\"\r\nlet count = 1\r\n"
        let after = "let greeting = \"Hello 🙂\"\r\nlet count = 2\r\n"
        let diff = try await FileDiff.compare(before: before, after: after)
        let spans = SyntaxHighlighter.diffSpans(in: diff, before: before, after: after, language: .swift)
        let added = try XCTUnwrap(diff.lines.firstIndex { $0.kind == .added && $0.text.contains("greeting") })
        XCTAssertEqual(diff.addedCount, 2)
        XCTAssertEqual(diff.removedCount, 2)
        XCTAssertTrue(diff.lines.allSatisfy { !$0.text.contains("\r") })
        let token = try XCTUnwrap(spans[added].first { $0.kind == .string })
        XCTAssertEqual((diff.lines[added].text as NSString).substring(with: token.range), "\"Hello 🙂\"")
        XCTAssertNotNil(Range(token.range, in: diff.lines[added].text))
        XCTAssertTrue(SyntaxHighlighter.diffSpans(in: diff, before: before, after: after, language: .plain).allSatisfy(\.isEmpty))
    }
}

@MainActor final class NativeEditorTests: XCTestCase {
    func testUndoCannotChangeAnotherFileInTheSameWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        let first = CodeTextView(), second = CodeTextView()
        window.contentView?.addSubview(first); window.contentView?.addSubview(second)
        first.string = "one"; second.string = "two"
        let oneUndo = try XCTUnwrap(first.undoManager), twoUndo = try XCTUnwrap(second.undoManager)
        defer { oneUndo.removeAllActions(); twoUndo.removeAllActions() }
        oneUndo.groupsByEvent = false; twoUndo.groupsByEvent = false
        oneUndo.beginUndoGrouping()
        first.insertText("!", replacementRange: NSRange(location: 3, length: 0))
        oneUndo.endUndoGrouping()
        twoUndo.beginUndoGrouping()
        second.insertText("?", replacementRange: NSRange(location: 3, length: 0))
        twoUndo.endUndoGrouping()
        oneUndo.undo()
        XCTAssertEqual(first.string, "one")
        XCTAssertEqual(second.string, "two?")
        twoUndo.undo()
        XCTAssertEqual(second.string, "two")
    }

    func testLongLinesRemainOneLayoutLineAndHighlightingPreservesSource() throws {
        let view = CodeEditorView(), editor = view.editor
        editor.setFrameSize(NSSize(width: 300, height: 200))
        let firstLine = "let value = \"" + String(repeating: "long ", count: 100) + "\""
        let source = firstLine + "\nlet next = 2\n"
        editor.string = source; editor.refreshLines()
        let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        var glyphRange = NSRange()
        let fragment = layout.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: &glyphRange)
        XCTAssertGreaterThan(fragment.width, 300)
        XCTAssertGreaterThanOrEqual(glyphRange.length, (firstLine as NSString).length)
        XCTAssertFalse(container.widthTracksTextView)
        XCTAssertTrue(editor.isHorizontallyResizable)
        XCTAssertEqual(editor.lines.count, 3)
        editor.highlight(SyntaxHighlighter.spans(in: source, language: .swift))
        XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        editor.applyTheme()
        XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertEqual(editor.string, source)
        let scroll = view.scroll
        view.setFrameSize(NSSize(width: 400, height: 300))
        view.layout()
        scroll.tile()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(editor.visibleRect.minX, 0)
        XCTAssertEqual(editor.visibleRect.minY, 0)
        XCTAssertEqual(scroll.frame.minX, view.gutter.frame.maxX)
        let rulerFrame = view.gutter.frame
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(editor.visibleRect.minX, 0)
        XCTAssertEqual(view.gutter.frame, rulerFrame)
    }
}
