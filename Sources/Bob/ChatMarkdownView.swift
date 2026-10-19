import AppKit
import SwiftUI

/// A transcript-sized rich text view, not a nested scroll view. Each text update
/// is parsed immediately; no completed-message or closed-fence signal is needed.
struct ChatMarkdownView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> ChatMarkdownTextView {
        ChatMarkdownTextView()
    }

    func updateNSView(_ text: ChatMarkdownTextView, context: Context) {
        text.update(markdown: markdown)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatMarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return nsView.fittingSize(for: width)
    }
}

final class ChatMarkdownTextView: NSTextView {
    private var markdown: String?

    init() {
        // Use TextKit 1 explicitly for attributed block layout and measurement.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        setAccessibilityLabel("Assistant response")
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(markdown: String) {
        guard self.markdown != markdown else { return }
        self.markdown = markdown
        let selection = selectedRanges
        textStorage?.setAttributedString(PlanMarkdownFormatter.render(markdown, compactEdges: true))
        // Preserve a user's selection while the response continues to grow.
        selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= (string as NSString).length }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func fittingSize(for width: CGFloat) -> CGSize {
        guard let textContainer, let layoutManager else { return CGSize(width: width, height: 0) }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).maxY
        return CGSize(width: width, height: ceil(height))
    }
}
