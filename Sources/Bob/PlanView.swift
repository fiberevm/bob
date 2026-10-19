import AppKit
import SwiftUI

struct PlanView: View {
    @ObservedObject var store: AppStore
    private var markdown: String { store.selected?.plan ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Plan", systemImage: "list.bullet.rectangle").fontWeight(.medium)
                if let title = store.selected?.title {
                    Text(title).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                } label: { Label("Copy Markdown", systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).disabled(markdown.isEmpty).help("Copy the plan as Markdown")
            }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 39)
                .background(Theme.panel).overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.muted)
                    Text("No plan yet").font(.system(size: 16, weight: .medium))
                    Text("Ask Bob to create a detailed plan. It will appear here and stay with this chat.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlanMarkdownView(markdown: markdown).id(store.selectedID)
            }
        }.background(Theme.background).foregroundStyle(Theme.text)
    }
}

/// Render Foundation's Markdown syntax as native, selectable rich text.
struct PlanMarkdownView: NSViewRepresentable {
    let markdown: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 28, height: 24)
        text.usesFindBar = true
        text.setAccessibilityLabel("Plan document")
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.markdown != markdown, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.markdown = markdown
        text.textStorage?.setAttributedString(PlanMarkdownFormatter.render(markdown))
    }
    final class Coordinator { var markdown: String? }
}

@MainActor enum PlanMarkdownFormatter {
    private struct Block {
        let id: Int
        let intent: [PresentationIntent.IntentType]
        var content: AttributedString
    }

    static func render(_ markdown: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
        }
        var blocks: [Block] = []
        for run in parsed.runs {
            let intent = run.presentationIntent?.components ?? []
            let id = intent.first?.identity ?? 0
            let content = AttributedString(parsed[run.range])
            if blocks.last?.id == id { blocks[blocks.count - 1].content.append(content) }
            else { blocks.append(Block(id: id, intent: intent, content: content)) }
        }
        let result = NSMutableAttributedString(string: "")
        var tables: [Int: NSTextTable] = [:]
        var seenItems = Set<Int>()
        for block in blocks {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 10
            var font = NSFont.systemFont(ofSize: 14)
            var color = NSColor.labelColor
            var code = false
            for component in block.intent {
                switch component.kind {
                case .header(let level):
                    font = .systemFont(ofSize: [28, 22, 18, 16, 14, 14][min(max(level - 1, 0), 5)], weight: .semibold)
                    paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : 16
                    paragraph.paragraphSpacing = 10
                case .codeBlock:
                    code = true
                    font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                    paragraph.lineSpacing = 3
                    let box = NSTextBlock()
                    box.backgroundColor = .controlBackgroundColor
                    box.setWidth(12, type: .absoluteValueType, for: .padding)
                    paragraph.textBlocks = [box]
                case .blockQuote:
                    paragraph.headIndent += 18
                    paragraph.firstLineHeadIndent += 18
                    color = .secondaryLabelColor
                default: break
                }
            }
            let value = NSMutableAttributedString(string: "")
            for run in block.content.runs {
                let inline = run.inlinePresentationIntent ?? []
                var runFont = code || inline.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : font
                if inline.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if inline.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if inline.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
                if let link = run.link { attributes[.link] = link; attributes[.foregroundColor] = NSColor.linkColor }
                value.append(NSAttributedString(string: String(block.content[run.range].characters), attributes: attributes))
            }
            let listItems = block.intent.filter { if case .listItem = $0.kind { return true }; return false }
            if let item = listItems.first, case .listItem(let ordinal) = item.kind {
                paragraph.firstLineHeadIndent += CGFloat(max(0, listItems.count - 1)) * 22
                paragraph.headIndent = paragraph.firstLineHeadIndent + 24
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                paragraph.paragraphSpacing = 6
                if seenItems.insert(item.identity).inserted {
                    let ordered = block.intent.first { $0.kind == .orderedList || $0.kind == .unorderedList }?.kind == .orderedList
                    var marker = ordered ? "\(ordinal)." : "•"
                    if value.string.hasPrefix("[ ] ") || value.string.lowercased().hasPrefix("[x] ") {
                        marker = value.string.hasPrefix("[ ] ") ? "☐" : "☑"
                        value.deleteCharacters(in: NSRange(location: 0, length: 4))
                    }
                    value.insert(NSAttributedString(string: marker + "\t", attributes: [.font: font, .foregroundColor: color]), at: 0)
                } else { paragraph.firstLineHeadIndent = paragraph.headIndent }
            }
            if let tableIntent = block.intent.first(where: { if case .table = $0.kind { return true }; return false }),
               case .table(let columns) = tableIntent.kind,
               let cell = block.intent.first(where: { if case .tableCell = $0.kind { return true }; return false }),
               case .tableCell(let column) = cell.kind {
                let table = tables[tableIntent.identity] ?? NSTextTable()
                table.numberOfColumns = columns.count
                table.collapsesBorders = true
                tables[tableIntent.identity] = table
                let row = block.intent.compactMap { component -> Int? in
                    if case .tableRow(let index) = component.kind { return index }; return nil
                }.first ?? 0
                let cellBlock = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cellBlock.setWidth(8, type: .absoluteValueType, for: .padding)
                cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                cellBlock.setBorderColor(.separatorColor)
                if row == 0 { cellBlock.backgroundColor = .controlBackgroundColor }
                paragraph.textBlocks = [cellBlock]
                paragraph.paragraphSpacing = 0
                paragraph.alignment = columns[column].alignment == .right ? .right : columns[column].alignment == .center ? .center : .left
            }
            if !value.string.hasSuffix("\n") { value.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color])) }
            value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
            result.append(value)
        }
        return result
    }
}
