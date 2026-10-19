import SwiftUI
import BobCore

struct ModelEffortControls: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: 14) {
            modelMenu
            effortMenu
        }
        .frame(height: 26).fixedSize()
    }

    private var modelMenu: some View {
        Menu {
            ForEach(store.modelGroups) { group in
                Section(group.provider.title) {
                    if group.models.isEmpty {
                        Button("Configure models…") {
                            store.settingsProvider = group.provider
                            store.showSettings = true
                        }
                    }
                    ForEach(group.models) { model in
                        Button { store.selectModel(model, provider: group.provider) } label: {
                            if store.selectedProvider == group.provider && store.selectedModelID == model.id {
                                Label(model.name, systemImage: "checkmark")
                            } else { Text(model.name) }
                        }
                    }
                }
            }
            if !store.modelGroups.isEmpty { Divider() }
            Button(store.modelGroups.isEmpty ? "Connect a provider…" : "Manage providers…") {
                store.settingsProvider = store.selectedProvider
                store.showSettings = true
            }
        } label: {
            HStack(spacing: 7) {
                Text(store.selectedModelName).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
                chevron
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(store.isRunning)
        .accessibilityLabel("Model").accessibilityValue(store.selectedModelName).help("Choose model")
    }

    private var effortMenu: some View {
        Menu {
            Button { store.selectReasoningEffort(nil) } label: {
                if store.selectedReasoningEffort == nil { Label("Auto", systemImage: "checkmark") }
                else { Text("Auto") }
            }
            Divider()
            ForEach(store.availableReasoningEfforts, id: \.self) { effort in
                Button { store.selectReasoningEffort(effort) } label: {
                    if store.selectedReasoningEffort == effort {
                        Label(ModelReasoning.title(for: effort), systemImage: "checkmark")
                    } else { Text(ModelReasoning.title(for: effort)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(ModelReasoning.title(for: store.selectedReasoningEffort))
                chevron
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .disabled(store.isRunning || store.availableReasoningEfforts.isEmpty)
        .accessibilityLabel("Effort").accessibilityValue(ModelReasoning.title(for: store.selectedReasoningEffort))
        .help(store.availableReasoningEfforts.isEmpty ? "This model does not offer an effort setting" : "Choose effort")
    }
    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
    }
}

/// Shared by the floating composer and workspace tabs.
struct FloatingGlass: ViewModifier {
    // A large radius preserves the capsule used by tabs; composers keep
    // consistent corners as their multiline text field grows.
    var cornerRadius: CGFloat = 1_000
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Theme.panel, in: shape)
                .overlay { shape.strokeBorder(Theme.line, lineWidth: 1) }
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(Theme.line.opacity(0.65), lineWidth: 1) }
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }
}
