import SwiftUI
import AppKit
import BobCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var auth: ChatGPTAuth
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderKind = .chatgpt
    @State private var openAIKey = ""
    @State private var claudeKey = ""
    @State private var compatibleKey = ""
    @State private var models: [AvailableModel] = []
    @State private var loadingModels = false
    @State private var status: String?
    var body: some View {
        VStack(spacing: 0) {
            Text("Models").font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider().overlay(Theme.line)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 5) {
                    ForEach(ProviderKind.allCases) { item in
                        Button {
                            provider = item; models = store.connections.models(for: item); status = nil
                            if item == .claudeCode { Task { await loadModels() } }
                        } label: {
                            Text(item.title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }.buttonStyle(NavigationRowStyle(selected: item == provider))
                    }
                    Spacer()
                }.padding(14).frame(width: 195).background(Theme.panel)
                Rectangle().fill(Theme.line).frame(width: 1)
                FadingScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if provider == .chatgpt { chatGPTSection }
                        else if provider == .claudeCode { claudeSection }
                        else {
                            if provider == .compatible {
                                field("Base URL") { TextField("http://localhost:11434/v1", text: $store.settings.baseURL).help("OpenAI-compatible Chat Completions endpoint, including its API prefix") }
                            }
                            field(provider == .compatible ? "API key (optional)" : "API key") {
                                SecureField("", text: keyBinding).help("Stored in macOS Keychain. API billing applies.")
                            }
                        }
                        Divider().overlay(Theme.line)
                        field("Model ID") {
                            TextField("", text: modelBinding)
                        }
                        Button { Task { await loadModels() } } label: {
                            HStack(spacing: 8) {
                                if loadingModels { ProgressView().controlSize(.small) }
                                Text("Load models")
                            }
                        }.disabled(loadingModels || auth.isSigningIn || store.connections.claude.isSigningIn)
                        ForEach(models, id: \.id) { model in
                            Button { modelBinding.wrappedValue = model.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.name).font(.system(size: 11, weight: .medium))
                                        if model.name != model.id { Text(model.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted) }
                                    }
                                    Spacer()
                                    if modelBinding.wrappedValue == model.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }.padding(10).background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                        if let status { Text(status).font(.system(size: 11)).foregroundStyle(Theme.warning).textSelection(.enabled) }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().overlay(Theme.line)
            HStack {
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).tint(Theme.action).keyboardShortcut(.defaultAction)
                    .disabled(store.connections.claude.isSigningIn)
            }.padding(20)
        }.frame(width: 760, height: 650).background(Theme.background).foregroundStyle(Theme.text).tint(Theme.accent)
            .onAppear {
                provider = store.settingsProvider
                models = store.connections.models(for: provider)
                do { openAIKey = try SecretStore.read("openai"); claudeKey = try SecretStore.read("claude"); compatibleKey = try SecretStore.read("compatible") }
                catch { status = error.localizedDescription }
            }
            .onDisappear { store.connections.claude.cancelSignIn() }
    }
    private var chatGPTSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            if !auth.accounts.isEmpty {
                Picker("Account", selection: $auth.selectedID) {
                    Text("Choose account").tag(String?.none)
                    ForEach(auth.accounts) { account in Text(account.label).tag(Optional(account.id)) }
                }.onChange(of: auth.selectedID) { _, _ in models = store.connections.models(for: .chatgpt) }
            }
            HStack {
                Button(auth.isSigningIn ? "Waiting for browser…" : auth.hasPendingRegistration ? "Retry sign-in" : "Continue with ChatGPT") {
                    signIn(auth.hasPendingRegistration ? .pendingRegistration : .newAccount)
                }.disabled(auth.isSigningIn)
                if auth.isSigningIn { Button("Cancel") { auth.cancelSignIn() } }
                else if auth.hasPendingRegistration {
                    Button("Use a different account") { signIn(.newAccount) }
                }
            }
            if let account = auth.selected {
                HStack {
                    Button("Sign in again") {
                        signIn(.account(account))
                    }
                    Button("Sign out") { Task { do { try await auth.signOut() } catch { status = error.localizedDescription } } }
                    Link("Usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                }.font(.system(size: 10)).disabled(auth.isSigningIn)
            }
        }
    }
    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.connections.claude.executable == nil {
                Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            } else if store.connections.claude.isConnected {
                Text(store.connections.claude.accountLabel).font(.system(size: 12))
                Button("Use Claude") {
                    store.newSession(provider: .claudeCode)
                    if let model = models.first(where: { $0.id == store.settings[.claudeCode] }) ?? models.first {
                        store.selectModel(model, provider: .claudeCode)
                    }
                    dismiss()
                }.disabled(store.connections.claude.isSigningIn)
            }
            HStack {
                Button(store.connections.claude.isSigningIn ? "Waiting for browser…" : store.connections.claude.isConnected ? "Sign in again" : "Continue with Claude") {
                    Task {
                        do { try await store.connections.claude.signIn(); await loadModels() }
                        catch is CancellationError {} catch { status = error.localizedDescription }
                    }
                }.disabled(store.connections.claude.isSigningIn || store.connections.claude.executable == nil)
                if store.connections.claude.isSigningIn { Button("Cancel") { store.connections.claude.cancelSignIn() } }
            }
            if store.connections.claude.isSigningIn {
                TerminalTextView(session: store.connections.claude.loginTerminal)
                    .frame(height: 180).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Claude sign-in terminal")
            }
        }
    }
    private func signIn(_ target: ChatGPTAuth.SignInTarget) {
        status = nil
        Task {
            do { try await auth.signIn(target); await loadModels() }
            catch is CancellationError {} catch { status = error.localizedDescription }
        }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).accessibilityLabel(label)
        }
    }
    private var keyBinding: Binding<String> {
        switch provider {
        case .openai: return $openAIKey
        case .claude: return $claudeKey
        default: return $compatibleKey
        }
    }
    private var modelBinding: Binding<String> {
        Binding(get: { store.settings[provider] }, set: { store.settings[provider] = $0 })
    }
    private func save() {
        do {
            try SecretStore.write(openAIKey, account: "openai")
            try SecretStore.write(claudeKey, account: "claude")
            try SecretStore.write(compatibleKey, account: "compatible")
            store.connections.savedCredentials(openAI: openAIKey, claude: claudeKey, compatible: compatibleKey, configureCompatible: provider == .compatible)
            Task { await store.connections.refreshCatalogs() }
            store.saveNow(); dismiss()
        } catch { status = error.localizedDescription }
    }
    private func loadModels() async {
        let requestedProvider = provider
        loadingModels = true; status = nil
        defer { loadingModels = false }
        do {
            let base: String, key: String
            let account = auth.selectedID
            switch provider {
            case .chatgpt: base = "https://api.openai.com/v1"; key = try await auth.accessToken()
            case .openai: base = "https://api.openai.com/v1"; key = openAIKey
            case .claude: base = "https://api.anthropic.com/v1"; key = claudeKey
            case .claudeCode: base = ""; key = ""
            case .compatible: base = store.settings.baseURL; key = compatibleKey
            }
            let catalog = try await store.connections.loadModels(provider: requestedProvider, baseURL: base, token: key, accountID: account)
            guard requestedProvider == provider else { return }
            models = catalog
            if modelBinding.wrappedValue.isEmpty, let first = models.first { modelBinding.wrappedValue = first.id }
            if models.isEmpty { status = "The provider returned no models. You can enter a model ID manually." }
        } catch { if requestedProvider == provider { status = error.localizedDescription } }
    }
}

