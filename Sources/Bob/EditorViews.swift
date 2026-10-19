import SwiftUI
import AppKit
import BobCore

struct EditorView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        if let path = store.editorPath {
            FileEditorView(store: store, path: path).id(path)
        } else {
            EmptyPanel(title: "Select a file")
        }
    }
}

struct ChangesView: View {
    @ObservedObject var store: AppStore
    @State private var selectedPath: String?
    @State private var refreshID = UUID()

    private var selectedChange: GitFileChange? {
        store.git.changes.first { $0.path == selectedPath } ?? store.git.changes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.git.isRepository {
                HStack {
                    Text("Changes").foregroundStyle(Theme.secondary)
                    Text("\(store.git.changes.count)").foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Refresh") { store.refresh() }
                    Button("Review") { store.reviewChanges() }
                }.font(.system(size: 11)).padding(.horizontal, 18).frame(height: 39).background(Theme.panel)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            }
            if !store.git.isRepository {
                EmptyPanel(title: "No Git repository")
            } else if store.git.changes.isEmpty {
                EmptyPanel(title: "No changes")
            } else {
                HSplitView {
                    FadingScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(store.git.changes, id: \.path) { change in
                                Button { selectedPath = change.path } label: {
                                    HStack(spacing: 7) {
                                        FileIcon(path: change.path)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(URL(fileURLWithPath: change.path).lastPathComponent)
                                                .foregroundStyle(Theme.text)
                                            Text(relativePath(change.path)).font(.system(size: 10))
                                                .foregroundStyle(Theme.muted)
                                        }.lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        Text(change.kind.badge).foregroundStyle(change.kind.color)
                                            .help(change.kind.label)
                                    }.font(.system(size: 12)).padding(8).contentShape(Rectangle())
                                }.buttonStyle(NavigationRowStyle(selected: selectedChange?.path == change.path))
                                    .help(relativePath(change.path))
                                    .accessibilityLabel(relativePath(change.path))
                                    .accessibilityValue(change.kind.label)
                                    .accessibilityAddTraits(selectedChange?.path == change.path ? .isSelected : [])
                            }
                        }.padding(6)
                    }.frame(minWidth: 170, idealWidth: 240, maxWidth: 340).background(Theme.panel)
                    if let change = selectedChange {
                        ChangedFileDetail(store: store, change: change, refreshID: refreshID)
                            .id(change.path)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.onReceive(store.$git) { _ in refreshID = UUID() }
    }

    private func relativePath(_ path: String) -> String {
        path.hasPrefix(store.projectPath + "/") ? String(path.dropFirst(store.projectPath.count + 1)) : path
    }
}

private struct ChangedFileDetail: View {
    @ObservedObject var store: AppStore
    let change: GitFileChange
    let refreshID: UUID
    @State private var diff: FileDiff?
    @State private var before = ""
    @State private var after = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(change.path.replacingOccurrences(of: store.projectPath + "/", with: ""))
                    .lineLimit(1).truncationMode(.middle).help(change.path)
                Spacer()
                if let diff {
                    Text("+\(diff.addedCount)").foregroundStyle(Theme.added)
                    Text("−\(diff.removedCount)").foregroundStyle(Theme.removed)
                }
            }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 39)
                .background(Theme.panel).overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            if let error {
                EmptyPanel(title: error)
            } else if let diff {
                if diff.lines.isEmpty {
                    EmptyPanel(title: change.kind == .renamed ? "File renamed; contents unchanged" :
                               change.kind == .added || change.kind == .untracked ? "New empty file" : "No content changes")
                } else {
                    FileDiffView(diff: diff, path: change.path, before: before, after: after)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task(id: refreshID) {
            diff = nil; error = nil
            do {
                let current = change.kind == .deleted ? "" : try await store.fileService(path: store.projectPath).read(change.path)
                let original = try await store.comparisonBase(for: change.path, fallback: current)
                let result = try await FileDiff.compare(before: original.text, after: current)
                try Task.checkCancellation()
                before = original.text; after = current; diff = result
            } catch is CancellationError {} catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct FileBrowserView: View {
    @ObservedObject var store: AppStore
    @State private var fileAction: FileTreeAction?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Files").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    FileTreeCreationMenu(directory: store.projectPath) { fileAction = $0 }
                } label: { Image(systemName: "plus").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New File or Folder").accessibilityLabel("New File or Folder").disabled(store.isMutatingFiles)
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }.buttonStyle(.plain).help("Refresh Project")
            }.foregroundStyle(Theme.muted).padding(.horizontal, 17).frame(height: 42)
            if store.git.isRepository {
              HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.muted)
                Text(store.git.branch).lineLimit(1)
                Spacer()
              }.font(.system(size: 11)).padding(.horizontal, 17).padding(.bottom, 12)
            }
            FileTreeView(tree: store.fileTree, selectedPath: store.editorPath, projectPath: store.projectPath, changes: store.fileChanges,
                         isMutatingFiles: store.isMutatingFiles, openFile: { store.openFile($0) },
                         performAction: { fileAction = $0 }, onError: { store.error = $0 })
            if let checkpoint = store.checkpoints.first {
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Checkpoint").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button { store.undoFile() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 10)) }.buttonStyle(.plain).disabled(store.checkpoints.isEmpty).help("Undo Last Bob File Edit")
                }
                Text(URL(fileURLWithPath: checkpoint.path).lastPathComponent).font(.system(size: 10)).lineLimit(1)
            }.padding(17)
            }
        }.background(Theme.panel)
            .sheet(item: $fileAction) { FileTreeActionSheet(store: store, action: $0) }
    }
}

private struct FileTreeView: View {
    @ObservedObject var tree: FileTree
    let selectedPath: String?
    let projectPath: String
    let changes: [String: FileChangeKind]
    let isMutatingFiles: Bool
    let openFile: (String) -> Void
    let performAction: (FileTreeAction) -> Void
    let onError: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FadingScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(tree.rows) { row in
                    let file = row.entry, expanded = tree.expandedPaths.contains(row.id)
                    let change = changes[file.path]
                    let containsChanges = file.isDirectory && changes.keys.contains { $0.hasPrefix(file.path + "/") }
                    Button {
                        if file.isDirectory {
                            Task {
                                do { try await tree.toggleFolder(file) }
                                catch { onError(error.localizedDescription) }
                            }
                        } else { openFile(file.path) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .opacity(file.isDirectory ? 1 : 0).frame(width: 8)
                            FileIcon(path: file.path, isDirectory: file.isDirectory)
                            Text(file.name).font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(change?.color ?? (containsChanges ? Theme.warning : Theme.secondary))
                            Spacer(minLength: 0)
                            if let change {
                                Text(change.badge).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(change.color)
                                    .help(change.label)
                            } else if containsChanges {
                                Circle().fill(Theme.warning).frame(width: 5, height: 5)
                            }
                            if tree.loadingPaths.contains(row.id) { ProgressView().controlSize(.mini) }
                        }.foregroundStyle(Theme.secondary)
                            .padding(.leading, 8 + CGFloat(row.depth) * 14).padding(.trailing, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }.buttonStyle(NavigationRowStyle(selected: file.path == selectedPath))
                        .disabled(isMutatingFiles || (tree.isRefreshing && file.isDirectory))
                        .accessibilityLabel(file.name)
                        .accessibilityValue([file.isDirectory ? (expanded ? "Expanded" : "Collapsed") : (file.path == selectedPath ? "Selected" : ""), change?.label ?? (containsChanges ? "Contains changes" : "")].filter { !$0.isEmpty }.joined(separator: ", "))
                        .help(file.path.replacingOccurrences(of: projectPath + "/", with: ""))
                        .contextMenu {
                            FileTreeCreationMenu(directory: file.isDirectory ? file.path : URL(fileURLWithPath: file.path).deletingLastPathComponent().path,
                                                 performAction: performAction)
                            Divider()
                            Button { performAction(FileTreeAction(.rename, entry: file)) } label: { Label("Rename…", systemImage: "pencil") }
                                .disabled(changes[file.path] == .deleted)
                            Button(role: .destructive) { performAction(FileTreeAction(.trash, entry: file)) } label: { Label("Move to Trash…", systemImage: "trash") }
                                .disabled(changes[file.path] == .deleted)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }.padding(.horizontal, 6)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: tree.rows.map(\.id))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: tree.expandedPaths)
        }.contextMenu {
            FileTreeCreationMenu(directory: projectPath, performAction: performAction)
        }
    }
}
