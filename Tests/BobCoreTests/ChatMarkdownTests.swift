import AppKit
import SwiftUI
import XCTest
@testable import Bob

@MainActor
final class ChatMarkdownTests: XCTestCase {
    func testChatRemovesTrailingParagraphGapButKeepsInternalSpacing() throws {
        let rendered = PlanMarkdownFormatter.render("First\n\nLast", compactEdges: true)
        XCTAssertEqual(rendered.string, "First\nLast")
        let first = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let last = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: rendered.length - 1, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(first.paragraphSpacing, 10)
        XCTAssertEqual(last.paragraphSpacing, 0)
        XCTAssertTrue(PlanMarkdownFormatter.render("Last").string.hasSuffix("\n"))
    }

    func testTablesHaveOuterVerticalMarginsAndKeepTheirFinalParagraph() throws {
        let markdown = "Before\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let rendered = PlanMarkdownFormatter.render(markdown, compactEdges: true)
        let cellRange = (rendered.string as NSString).range(of: "2")
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: cellRange.location, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(cell.table.width(for: .margin, edge: .minY), 14)
        XCTAssertEqual(cell.table.width(for: .margin, edge: .maxY), 14)
        XCTAssertEqual(style.paragraphSpacing, 0)
        XCTAssertTrue(rendered.string.hasSuffix("\n"))
    }

    func testStreamingUpdatesRenderBeforeMarkdownIsComplete() throws {
        let view = ChatMarkdownTextView()
        view.update(markdown: "# Summary\n\n**Ready**\n\n```swift\nlet val")
        XCTAssertTrue(view.string.hasPrefix("Summary\nReady\n"))
        XCTAssertTrue(view.string.contains("let val"))
        let heading = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(heading.pointSize, 28)
        let code = (view.string as NSString).range(of: "let val")
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch)

        view.update(markdown: "# Summary\n\n**Ready**\n\n```swift\nlet value = true\n```\n\n- First\n- Second")
        XCTAssertTrue(view.string.contains("let value = true"))
        XCTAssertTrue(view.string.contains("•\tSecond"))
        XCTAssertFalse(view.string.contains("```"))
    }

    func testEveryPartialPrefixCanBeRendered() {
        let view = ChatMarkdownTextView()
        let markdown = "# Result\n\n**bold** and [link](https://example.com)\n\n```swift\nlet x = 1\n```\n\n- Done\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        for end in markdown.indices {
            view.update(markdown: String(markdown[...end]))
            let size = view.fittingSize(for: 320)
            XCTAssertTrue(size.height.isFinite)
        }
        XCTAssertTrue(view.string.contains("Done"))
        XCTAssertTrue(view.string.contains("2"))
    }

    func testLayoutGrowsAndReflowsWithoutAnInnerScrollView() {
        let view = ChatMarkdownTextView()
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        view.update(markdown: "Short response")
        let short = view.fittingSize(for: 500)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.update(markdown: "Short response\n\n" + String(repeating: "More streamed content with **formatting**. ", count: 40))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5))
        let wide = view.fittingSize(for: 500)
        let narrow = view.fittingSize(for: 220)
        XCTAssertGreaterThan(wide.height, short.height)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertNil(view.enclosingScrollView)
    }
}
