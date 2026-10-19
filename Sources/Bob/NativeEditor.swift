import AppKit
import SwiftUI

struct NativeEditor: NSViewRepresentable {
    @Binding var text: String
    let path: String
    var focusRequest: UUID? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> CodeEditorView {
        let view = CodeEditorView()
        let editor = view.editor
        editor.delegate = context.coordinator
        editor.string = text
        editor.refreshLines()
        context.coordinator.refresh(editor, path: path)
        resetScrollPosition(view)
        return view
    }

    func updateNSView(_ view: CodeEditorView, context: Context) {
        context.coordinator.text = $text
        let editor = view.editor
        let changedFile = context.coordinator.path != path
        let changed = editor.string != text
        if changed {
            editor.string = text
            editor.undoManager?.removeAllActions()
            editor.refreshLines()
        }
        if changed || changedFile { context.coordinator.refresh(editor, path: path) }
        if changedFile { resetScrollPosition(view) }
        context.coordinator.requestFocus(editor, id: focusRequest)
    }

    static func dismantleNSView(_ view: CodeEditorView, coordinator: Coordinator) {
        coordinator.cancel()
        view.editor.delegate = nil
        view.editor.undoManager?.removeAllActions()
    }

    private func resetScrollPosition(_ view: CodeEditorView) {
        // Wait until SwiftUI has sized the editor before resetting a newly opened file.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.scroll.contentView.scroll(to: .zero)
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private(set) var path = ""
        private var highlightTask: Task<Void, Never>?
        private var focusedRequest: UUID?
        init(text: Binding<String>) { self.text = text }
        deinit { highlightTask?.cancel() }
        func cancel() { highlightTask?.cancel(); highlightTask = nil }
        func requestFocus(_ editor: CodeTextView, id: UUID?) {
            guard let id, id != focusedRequest else { return }
            focusedRequest = id
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window else { return }
                window.makeFirstResponder(editor)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? CodeTextView else { return }
            editor.refreshLines()
            text.wrappedValue = editor.string
            refresh(editor, path: path)
        }
        func refresh(_ editor: CodeTextView, path: String) {
            self.path = path
            highlightTask?.cancel()
            let source = editor.string, language = SourceLanguage(path: path)
            highlightTask = Task { [weak editor] in
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                let work = Task.detached(priority: .userInitiated) { SyntaxHighlighter.spans(in: source, language: language) }
                let spans = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let editor, editor.string == source else { return }
                editor.highlight(spans)
            }
        }
    }
}

final class CodeEditorView: NSView {
    let editor = CodeTextView()
    let scroll = NSScrollView()
    private(set) var gutter: LineNumberGutter!

    init() {
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.automaticallyAdjustsContentInsets = false
        scroll.documentView = editor
        gutter = LineNumberGutter(editor: editor, scroll: scroll)
        editor.gutter = gutter
        addSubview(gutter); addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = gutter.preferredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}

final class CodeTextView: AdaptiveTextView {
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }
    private(set) var lines = SourceLineMap("")
    weak var gutter: LineNumberGutter?
    private var spans: [SyntaxSpan] = []

    convenience init() {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isRichText = false; allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false; isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        backgroundColor = .clear; drawsBackground = false
        textContainerInset = NSSize(width: 10, height: 20)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true; isHorizontallyResizable = true
        autoresizingMask = [.width]
        container.widthTracksTextView = false; container.heightTracksTextView = false
        setAccessibilityLabel("Code editor")
        applyTheme()
    }

    func refreshLines() {
        lines = SourceLineMap(string)
        gutter?.refresh()
    }
    func highlight(_ spans: [SyntaxSpan]) {
        self.spans = spans
        let whole = NSRange(location: 0, length: (string as NSString).length)
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for span in spans where NSMaxRange(span.range) <= whole.length {
            layoutManager?.addTemporaryAttribute(.foregroundColor, value: span.kind.color, forCharacterRange: span.range)
        }
    }
    override func applyTheme() {
        super.applyTheme()
        highlight(spans)
        gutter?.needsDisplay = true
    }
}

extension SyntaxKind {
    var color: NSColor {
        switch self {
        case .comment: return .secondaryLabelColor
        case .string: return .systemRed
        case .number: return .systemOrange
        case .keyword: return .systemPurple
        case .type: return .systemTeal
        case .attribute: return .systemBlue
        }
    }
}

/// Draw only the visible logical lines, outside the scrollable document.
final class LineNumberGutter: NSView {
    private weak var editor: CodeTextView?
    private var scrollObserver: NSObjectProtocol?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private(set) var preferredWidth: CGFloat = 38
    override var isFlipped: Bool { true }

    init(editor: CodeTextView, scroll: NSScrollView) {
        self.editor = editor
        super.init(frame: .zero)
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        refresh()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

    func refresh() {
        let digits = max(2, String(editor?.lines.count ?? 1).count)
        let width = ceil((String(repeating: "0", count: digits) as NSString).size(withAttributes: [.font: numberFont]).width) + 24
        if preferredWidth != width { preferredWidth = width; superview?.needsLayout = true }
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        NSColor(Theme.panel).setFill(); bounds.fill()
        NSColor(Theme.line).setFill(); NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let origin = editor.textContainerOrigin
        let visible = editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = editor.lines.line(at: characters.location)
        let last = min(editor.lines.count - 1, editor.lines.line(at: NSMaxRange(characters)) + 1)
        let length = (editor.string as NSString).length
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor(Theme.muted)]
        for line in first...last {
            let offset = editor.lines.starts[line]
            let fragment: NSRect
            if offset < length {
                fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
            } else {
                fragment = layout.extraLineFragmentRect
            }
            let number = String(line + 1) as NSString
            let size = number.size(withAttributes: attributes)
            let y = convert(NSPoint(x: 0, y: origin.y + fragment.minY), from: editor).y
            number.draw(at: NSPoint(x: bounds.width - size.width - 12, y: y + max(0, (fragment.height - size.height) / 2)), withAttributes: attributes)
        }
    }
}
