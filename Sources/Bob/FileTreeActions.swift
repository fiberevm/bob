import SwiftUI
import BobCore

struct FileTreeAction: Identifiable {
    enum Kind { case newFile, newFolder, rename, trash }
    let id = UUID()
    let kind: Kind
    /// Parent folder for creation; the existing item for Rename and Trash.
    let path: String
    let isDirectory: Bool
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    init(_ kind: Kind, path: String, isDirectory: Bool = false) {
        self.kind = kind; self.path = path; self.isDirectory = isDirectory
    }
    init(_ kind: Kind, entry: FileEntry) { self.init(kind, path: entry.path, isDirectory: entry.isDirectory) }
    var title: String {
        switch kind {
        case .newFile: return "New file"
        case .newFolder: return "New folder"
        case .rename: return "Rename \(isDirectory ? "folder" : "file")"
        case .trash: return "Move “\(name)” to Trash?"
        }
    }
    var buttonTitle: String {
        switch kind {
        case .newFile, .newFolder: return "Create"
        case .rename: return "Rename"
        case .trash: return "Move to Trash"
        }
    }
}

struct FileTreeCreationMenu: View {
    let directory: String
    let performAction: (FileTreeAction) -> Void
    var body: some View {
        Button { performAction(FileTreeAction(.newFile, path: directory)) } label: { Label("New File…", systemImage: "doc.badge.plus") }
        Button { performAction(FileTreeAction(.newFolder, path: directory)) } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
    }
}

struct FileTreeActionSheet: View {
    @ObservedObject var store: AppStore
    let action: FileTreeAction
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var isWorking = false
    @State private var error: String?

    init(store: AppStore, action: FileTreeAction) {
        self.store = store; self.action = action
        _name = State(initialValue: action.kind == .rename ? action.name : "")
    }
    private var validationError: String? {
        guard action.kind != .trash else { return nil }
        do { try WorkspaceFiles.validateItemName(name); return nil }
        catch { return error.localizedDescription }
    }
    private var location: String {
        let path = action.kind == .rename ? URL(fileURLWithPath: action.path).deletingLastPathComponent().path : action.path
        if path == store.projectPath { return URL(fileURLWithPath: path).lastPathComponent }
        return path.hasPrefix(store.projectPath + "/") ? String(path.dropFirst(store.projectPath.count + 1)) : path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.kind == .trash ? "trash" : action.kind == .newFolder ? "folder.badge.plus" : action.kind == .rename ? "pencil" : "doc.badge.plus")
                    .font(.system(size: 20)).foregroundStyle(action.kind == .trash ? Theme.removed : Theme.muted)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 7) {
                    Text(action.title).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if action.kind == .trash {
                        Text(action.isDirectory ? "This folder and everything inside it will be moved to Trash. You can restore them in Finder." : "This file will be moved to Trash. You can restore it in Finder.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if action.kind != .trash {
                TextField(action.kind == .newFolder || action.isDirectory ? "Folder name" : "File name", text: $name)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13)).focused($nameFocused)
                    .accessibilityLabel(action.kind == .newFolder || action.isDirectory ? "Folder name" : "File name")
                    .disabled(isWorking)
            }
            Label { Text(location) } icon: {
                FileIcon(path: action.path, isDirectory: action.kind != .trash || action.isDirectory, size: 14)
            }
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(3).textSelection(.enabled)
            if let message = error ?? (name.isEmpty ? nil : validationError) {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                if action.kind == .trash {
                    Button(action.buttonTitle, role: .destructive) { submit() }.disabled(isWorking)
                } else {
                    Button(action.buttonTitle) { submit() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(Theme.action)
                        .disabled(isWorking || validationError != nil || (action.kind == .rename && name == action.name))
                }
            }
        }
        .padding(24).frame(width: 440).background(Theme.background).foregroundStyle(Theme.text).tint(Theme.accent)
        .interactiveDismissDisabled(isWorking)
        .task { nameFocused = action.kind != .trash }
        .onChange(of: name) { _, _ in error = nil }
    }

    private func submit() {
        guard !isWorking else { return }
        isWorking = true; error = nil
        Task {
            do {
                switch action.kind {
                case .newFile, .newFolder:
                    try await store.createFileTreeItem(named: name, in: action.path, isDirectory: action.kind == .newFolder)
                case .rename: try await store.renameFileTreeItem(action.path, to: name)
                case .trash: try await store.trashFileTreeItem(action.path)
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
            isWorking = false
        }
    }
}
