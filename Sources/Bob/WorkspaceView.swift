import SwiftUI
import BobCore

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.boundProjectPath.isEmpty {
                    ProjectLauncherView(store: store)
                } else {
                    HSplitView {
                        SidebarView(store: store).frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                        WorkspaceSplitView(store: store)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            WorkspaceStatusBar(store: store)
        }
        .background(Theme.background)
        .background(WorkspaceTabShortcuts(store: store))
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .navigationTitle(store.selected?.projectName ?? "Bob")
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store, auth: store.auth) }
        .sheet(isPresented: $store.showPalette) { CommandPalette(store: store) }
        .alert("Error", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: store.settings.baseURL) { _, _ in store.scheduleSave() }
        .task { await store.connections.refreshCatalogs() }
    }
}

struct WorkspacePanel: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.openTabs) { tab in
                                WorkspaceTabItem(store: store, tab: tab).id(tab.id)
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 5)
                    }.onChange(of: store.selectedTabID) { _, id in
                        if let id { reader.scrollTo(id) }
                    }
                }
                WorkspaceTabMenu(store: store).padding(.horizontal, 10)
                if store.selectedPanel == .terminal {
                    Button { store.terminal.clear() } label: { Image(systemName: "trash") }.help("Clear Terminal").padding(.trailing, 10)
                }
            }.font(.system(size: 11)).buttonStyle(.plain).frame(height: 42).background(Theme.panel)
            Theme.line.frame(height: 1)
            Group {
                if store.selectedTabID == nil {
                    EmptyPanel(title: "Open a tab with + or the Workspace menu")
                } else {
                    switch store.selectedPanel {
                    case .editor:
                        EditorSplitView(store: store)
                    case .plan: PlanView(store: store)
                    case .changes: ChangesView(store: store)
                    case .terminal: TerminalTextView(session: store.terminal)
                    case .browser: BrowserView(session: store.browser)
                    case .computer: ComputerView(session: store.computer, access: store.computer.access)
                    case .simulator: SimulatorView(session: store.simulator, visible: store.showWorkspacePanel)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Theme.background)
    }
}

struct WorkspaceTabMenu: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Menu {
            ForEach(WorkspacePanelKind.allCases, id: \.self) { kind in
                Button { store.openPanel(kind) } label: { Label(kind.rawValue, systemImage: kind.symbol) }
            }
        } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Open Tab").accessibilityLabel("Open Tab")
    }
}

private struct WorkspaceTabItem: View {
    @ObservedObject var store: AppStore
    let tab: WorkspaceTab
    private var selected: Bool { store.selectedTabID == tab.id }
    private var canClose: Bool { store.tabCanClose(tab) }
    var body: some View {
        HStack(spacing: 4) {
            Button { store.selectTab(tab.id) } label: {
                HStack(spacing: 7) {
                    if tab.kind == .editor, let path = store.buffer(for: tab.id)?.path {
                        FileIcon(path: path, size: 14)
                    } else {
                        Image(systemName: tab.kind.symbol).foregroundStyle(Theme.muted)
                    }
                    Text(store.tabTitle(tab)).lineLimit(1).truncationMode(.middle)
                        .fontWeight(selected ? .medium : .regular)
                    Spacer(minLength: 0)
                    if store.tabIsDirty(tab) { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                }.padding(.leading, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Capsule())
            }.help(store.buffer(for: tab.id)?.path ?? tab.kind.rawValue)
                .accessibilityLabel(store.tabTitle(tab))
                .accessibilityAddTraits(selected ? .isSelected : [])
            if canClose {
                Button { store.requestCloseTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 24).contentShape(Rectangle())
                }.help("Close \(store.tabTitle(tab))").accessibilityLabel("Close \(store.tabTitle(tab))")
                    .padding(.trailing, 8)
            }
        }.padding(.trailing, canClose ? 0 : 12)
            .frame(width: 150, height: 32)
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .background(selected ? Theme.selection : .clear, in: Capsule())
            .modifier(FloatingGlass())
    }
}

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingSessionID: UUID?
    @State private var editedName = ""
    @State private var showEditName = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.newSession() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").foregroundStyle(Theme.secondary)
                    Text("New Chat").fontWeight(.medium)
                    Spacer()
                }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 34)
            }.buttonStyle(NavigationRowStyle()).padding(.horizontal, 10).padding(.vertical, 12).help("New Chat · ⌘N")
            FadingScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(store.sessions) { session in
                            let status = store.sessionStatus(session)
                            HStack(spacing: 0) {
                                Button { store.select(session.id) } label: {
                                    HStack(alignment: .center, spacing: 8) {
                                        Text(session.title).font(.system(size: 12))
                                            .lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 0)
                                        if let status {
                                            Group {
                                                switch status {
                                                case .working: ProgressView().controlSize(.mini)
                                                case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.added)
                                                }
                                            }.frame(width: 14, height: 14).help(status.rawValue).accessibilityHidden(true)
                                        }
                                    }.padding(.vertical, 9).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(NavigationRowStyle(selected: session.id == store.selectedID))
                                    .accessibilityLabel(session.title).accessibilityValue(status?.rawValue ?? "")
                                Menu {
                                    Button("Edit name") {
                                        editingSessionID = session.id
                                        editedName = session.title
                                        showEditName = true
                                    }
                                    Button("Delete", role: .destructive) { store.deleteSession(session.id) }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 24, height: 28)
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("Conversation actions")
                                .accessibilityLabel("Actions for \(session.title)")
                            }
                                .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                        }
                }.padding(.horizontal, 10)
            }
        }.background(Theme.panel)
        .alert("Edit name", isPresented: $showEditName) {
            TextField("Conversation name", text: $editedName)
            Button("Cancel", role: .cancel) { editingSessionID = nil }
            Button("Save") {
                if let id = editingSessionID { store.renameSession(id, to: editedName) }
                editingSessionID = nil
            }.disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct ProjectLauncherView: View {
    @ObservedObject var store: AppStore
    @State private var recent = UserDefaults.standard.stringArray(forKey: "projects.recent") ?? []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !recent.isEmpty {
                Text("Recent projects").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 16)
                ForEach(Array(recent.prefix(5)), id: \.self) { path in
                    Button { store.onOpenProject?(path) } label: {
                        HStack {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium))
                            Spacer()
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(path)
                }
            }
        }.padding(28).frame(width: 420, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyPanel: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
