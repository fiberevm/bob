import SwiftUI
import BobCore

extension FileChangeKind {
    var color: Color {
        switch self {
        case .added, .untracked: return Theme.added
        case .deleted: return Theme.removed
        case .renamed: return Theme.accent
        case .modified, .conflicted: return Theme.warning
        }
    }
}

private enum FileEditorMode: Hashable { case edit, diff }
private struct BaselineKey: Equatable {
    let path: String
    let repository: String?
    let revision: String?
    let change: GitFileChange?
    let checkpoint: UUID?
    let saved: String
}
private struct DiffRequest: Equatable {
    let before: String?
    let after: String
}

struct FileEditorView: View {
    @ObservedObject var store: AppStore
    let path: String
    @State private var selectedMode: FileEditorMode?
    @State private var baseline: String?
    @State private var baselineLabel = "Saved file"
    @State private var baselineError: String?
    @State private var diffError: String?
    @State private var diff: FileDiff?
    @State private var isLoading = true
    @State private var isComparing = false

    private var change: FileChangeKind? { store.fileChanges[path] }
    private var hasChanges: Bool { change != nil || baseline.map { $0 != store.editorText } == true }
    private var mode: FileEditorMode { change == .deleted ? .diff : selectedMode ?? (hasChanges ? .diff : .edit) }
    private var baselineKey: BaselineKey {
        BaselineKey(path: path, repository: store.git.repositoryRoot, revision: store.git.revision,
                    change: store.git.changes.first { $0.path == path },
                    checkpoint: store.checkpoints.last { $0.path == path }?.id, saved: store.editorOriginal)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(path.replacingOccurrences(of: store.projectPath + "/", with: "")).lineLimit(1).truncationMode(.middle)
                    .help(path)
                if store.editorDirty { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                if let change { Text(change.badge).foregroundStyle(change.color).help(change.label) }
                Spacer(minLength: 8)
                if let diff, !diff.lines.isEmpty {
                    Text("+\(diff.addedCount)").foregroundStyle(Theme.added)
                    Text("−\(diff.removedCount)").foregroundStyle(Theme.removed)
                }
                if store.editorDirty {
                    Button("Discard") { store.editorText = store.editorOriginal }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
                if change != .deleted {
                    Picker("File view", selection: Binding(get: { mode }, set: { selectedMode = $0 })) {
                        Text("Edit").tag(FileEditorMode.edit)
                        Text("Diff").tag(FileEditorMode.diff)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 104)
                }
            }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 39).background(Theme.panel)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            Group {
                if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if mode == .edit {
                    NativeEditor(text: Binding(get: { store.editorText }, set: { selectedMode = .edit; store.editorText = $0 }),
                                 path: path, focusRequest: store.editorFocusRequest)
                } else if let error = baselineError ?? diffError {
                    EmptyPanel(title: error)
                } else if isComparing || diff == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diff, !diff.lines.isEmpty {
                    FileDiffView(diff: diff, path: path, before: baseline ?? "", after: store.editorText)
                } else {
                    EmptyPanel(title: change == .renamed ? "File renamed; contents unchanged" : change == .added || change == .untracked ? "New empty file" : "No changes")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if mode == .diff { Text("Compared with \(baselineLabel)") }
                else {
                    let count = SourceLineMap(store.editorText).count
                    Text("\(count) \(count == 1 ? "line" : "lines")")
                }
                Spacer()
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 12).frame(height: 25).background(Theme.panel)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        }
        .task(id: baselineKey) {
            isLoading = true; baselineError = nil
            do {
                let original = try await store.comparisonBase(for: path, fallback: store.editorOriginal)
                try Task.checkCancellation()
                baseline = original.text; baselineLabel = original.label
                isLoading = false
            } catch is CancellationError {} catch {
                baselineError = error.localizedDescription; isLoading = false
            }
        }
        .task(id: DiffRequest(before: baseline, after: store.editorText)) {
            guard let baseline else { return }
            isComparing = true; diffError = nil
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await FileDiff.compare(before: baseline, after: store.editorText)
                try Task.checkCancellation()
                diff = result; isComparing = false
            } catch is CancellationError {} catch {
                diffError = error.localizedDescription; isComparing = false
            }
        }
    }
}

struct FileDiffView: View {
    let diff: FileDiff
    let path: String
    let before: String
    let after: String
    @State private var syntax: [[SyntaxSpan]] = []

    private struct HighlightRequest: Equatable, Sendable {
        let diff: FileDiff
        let path: String
        let before: String
        let after: String
    }

    var body: some View {
        GeometryReader { geometry in
            FadingScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 0) {
                            Text(line.oldNumber.map(String.init) ?? "").foregroundStyle(Theme.muted).frame(width: 44, alignment: .trailing)
                            Text(line.newNumber.map(String.init) ?? "").foregroundStyle(Theme.muted).frame(width: 44, alignment: .trailing)
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").frame(width: 24)
                                .foregroundStyle(line.kind == .added ? Theme.added : line.kind == .removed ? Theme.removed : Theme.muted)
                            Text(highlighted(line, spans: syntax.indices.contains(index) ? syntax[index] : [])).fixedSize(horizontal: true, vertical: false)
                                .padding(.trailing, 16)
                            Spacer(minLength: 0)
                        }.font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .padding(.vertical, 3).frame(minWidth: geometry.size.width, alignment: .leading)
                            .background(line.kind == .added ? Theme.added.opacity(0.08) : line.kind == .removed ? Theme.removed.opacity(0.08) : line.kind == .hunk ? Theme.raised : .clear)
                    }
                }.padding(.vertical, 8)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    .textSelection(.enabled)
            }
        }.accessibilityLabel("File diff")
            .task(id: HighlightRequest(diff: diff, path: path, before: before, after: after)) {
                syntax = []
                let request = HighlightRequest(diff: diff, path: path, before: before, after: after)
                let work = Task.detached(priority: .userInitiated) {
                    SyntaxHighlighter.diffSpans(in: request.diff, before: request.before, after: request.after, language: SourceLanguage(path: request.path))
                }
                let spans = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                syntax = spans
            }
    }

    private func highlighted(_ line: FileDiff.Line, spans: [SyntaxSpan]) -> AttributedString {
        let source = line.text.isEmpty ? " " : line.text
        var text = AttributedString(source)
        text.foregroundColor = line.kind == .hunk ? Theme.accent : line.kind == .note ? Theme.muted : Theme.text
        for span in spans {
            guard let sourceRange = Range(span.range, in: source), let range = Range(sourceRange, in: text) else { continue }
            text[range].foregroundColor = Color(nsColor: span.kind.color)
        }
        return text
    }
}
