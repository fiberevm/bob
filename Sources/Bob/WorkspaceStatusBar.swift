import SwiftUI
import BobCore

struct WorkspaceStatusBar: View {
    @ObservedObject var store: AppStore
    @State private var showsUsage = false
    @State private var showsContext = false

    private var projectName: String {
        store.boundProjectPath.isEmpty ? "Open a project" : URL(fileURLWithPath: store.boundProjectPath).lastPathComponent
    }
    private var context: ContextUsage { store.selectedContextUsage }
    private var tokenUsage: ModelUsage? { store.selected?.totalTokenUsage }

    var body: some View {
        HStack(spacing: 16) {
            Button { store.openProject() } label: {
                Label(projectName, systemImage: "folder").lineLimit(1).truncationMode(.middle)
            }.help(store.boundProjectPath.isEmpty ? "Open Project · ⌘O" : store.boundProjectPath)
                .accessibilityLabel("Project: \(projectName)")
            if store.git.isRepository, !store.git.branch.isEmpty {
                Button { store.openPanel(.changes) } label: {
                    Label(store.git.branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                }.help("Show changes on \(store.git.branch)")
            }
            if let chat = store.selected {
                Label(chat.title, systemImage: "bubble.left").lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading).help(chat.title).layoutPriority(-1)
            }
            if let activity = store.selectedChatActivity {
                Label(activity, systemImage: store.approval != nil ? "hand.raised" : "circle.dotted")
                    .lineLimit(1).truncationMode(.tail).help(activity).layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if store.selected != nil {
                ModelEffortControls(store: store)
                Button { showsContext.toggle() } label: {
                    GeometryReader { geometry in
                        Capsule().fill(.white.opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule().fill((context.fraction ?? 0) >= 0.85 ? Color.yellow : .white)
                                    .frame(width: geometry.size.width * (context.fraction ?? 0))
                            }
                    }.frame(width: 72, height: 6)
                }.help("Context fill · click for details")
                    .accessibilityLabel("Chat context fill")
                    .accessibilityValue(context.fraction.map { "\(Int($0 * 100)) percent" } ?? "Context limit unavailable")
                    .popover(isPresented: $showsContext, arrowEdge: .top) { contextDetails }
                HStack(spacing: 10) {
                    Label("Sent \(tokenUsage.map { $0.inputTokens.formatted(.number.notation(.compactName)) } ?? "—")", systemImage: "arrow.up")
                    Label("Downloaded \(tokenUsage.map { $0.outputTokens.formatted(.number.notation(.compactName)) } ?? "—")", systemImage: "arrow.down")
                }.monospacedDigit().fixedSize()
                    .help(tokenUsage.map { "This chat: \($0.inputTokens.formatted()) input tokens sent · \($0.outputTokens.formatted()) output tokens received. Includes repeated input context and compaction; counts update when the provider reports usage." } ?? "The provider has not reported token usage for this chat.")
                    .accessibilityLabel("Selected chat token totals")
                    .accessibilityValue(tokenUsage.map { "\($0.inputTokens) input tokens, \($0.outputTokens) output tokens" } ?? "Not reported")
            }
            Button { showsUsage = true } label: {
                Label("Usage", systemImage: "chart.bar")
            }.help("Account limits and current chat usage")
                .popover(isPresented: $showsUsage, arrowEdge: .top) {
                    UsagePopover(store: store) {
                        showsUsage = false
                        store.settingsProvider = .chatgpt
                        store.showSettings = true
                    }
                }
        }
        .font(.system(size: 11)).buttonStyle(StatusBarButtonStyle())
        .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 26)
        .frame(maxWidth: .infinity).background(Theme.statusBar)
        .accessibilityElement(children: .contain).accessibilityLabel("Workspace status")
        .onChange(of: store.selectedID) { _, _ in showsContext = false; showsUsage = false }
    }

    private var contextDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Context usage").font(.system(size: 13, weight: .semibold))
            Text(store.selected?.title ?? "Chat").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            LabeledContent(context.isEstimated ? "Estimated context" : "Current context", value: "\(context.tokens.formatted()) tokens")
            if let budget = context.budget {
                LabeledContent(context.source == .localBudget ? "Bob's context budget" : "Model context window", value: "\(budget.formatted()) tokens")
                LabeledContent("Remaining", value: "\(max(0, budget - context.tokens).formatted()) tokens")
            } else {
                Text("The provider has not reported the model's context limit yet.").foregroundStyle(Theme.secondary)
            }
            if context.source == .localBudget {
                Text("Bob estimates the active messages, tool results, instructions, and model output, using provider counts when available. Older context is summarized as this local budget fills. This budget is separate from the model's maximum context window.")
                    .foregroundStyle(Theme.secondary)
            } else {
                Text(context.isEstimated
                     ? "Estimated from the available chat history. Claude manages compaction and may retain additional internal context. The model's context window is shown when the provider reports it."
                     : "Context uses the latest response's input and output, including cached input. Claude manages compaction; a provider-reported context window is shown when available.")
                    .foregroundStyle(Theme.secondary)
            }
            Divider()
            if let usage = tokenUsage {
                LabeledContent("Tokens sent ↑", value: usage.inputTokens.formatted())
                LabeledContent("Tokens downloaded ↓", value: usage.outputTokens.formatted())
            }
            Text("Chat totals count reported tokens across requests, including repeated input, chat titles, and compaction. They survive context summaries and restarts. Unreported usage is not estimated.")
                .foregroundStyle(Theme.secondary)
        }.font(.system(size: 11)).padding(18).frame(width: 320, alignment: .leading)
            .foregroundStyle(Theme.text).background(Theme.panel)
    }

}

private struct StatusBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Item(configuration: configuration)
    }
    private struct Item: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label.padding(.horizontal, 5).frame(height: 26)
                .background(.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0))
                .contentShape(Rectangle()).onHover { hovering = $0 }
        }
    }
}
