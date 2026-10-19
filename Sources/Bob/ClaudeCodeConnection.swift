import Foundation
import Combine
import BobCore

@MainActor final class ClaudeCodeConnection: ObservableObject {
    @Published private(set) var executable: URL?
    @Published private(set) var isConnected = false
    @Published private(set) var accountLabel = ""
    @Published private(set) var models: [AvailableModel] = []
    @Published private(set) var error: String?
    @Published private(set) var isSigningIn = false
    private(set) var checked = false
    private var refreshTask: Task<Void, Never>?
    let loginTerminal = TerminalSession()
    private var loginTask: Task<Void, Error>?
    private let executableOverride: URL?
    init(executable: URL? = nil) { executableOverride = executable; self.executable = executable ?? ExecutableLocator.find("claude") }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { [self] in
            defer { checked = true }
            executable = executableOverride ?? ExecutableLocator.find("claude")
            guard let executable else { isConnected = false; models = []; error = "Install Claude Code to connect your Claude subscription."; return }
            do {
                let result = try await ProcessRunner.run(executable, arguments: ["auth", "status", "--json"], environment: ClaudeCodeBackend.environment)
                let value = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any] ?? [:]
                let method = value["authMethod"] as? String ?? ""
                isConnected = value["loggedIn"] as? Bool == true && method == "claude.ai"
                guard isConnected else { models = []; error = "Sign in to Claude Code with your Claude account."; return }
                let plan = value["subscriptionType"] as? String
                accountLabel = [value["email"] as? String, plan.map { $0.capitalized }].compactMap { $0 }.joined(separator: " · ")
                models = try await ClaudeCodeBackend.loadModels(executable: executable)
                error = nil
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }
    func signIn() async throws {
        guard !isSigningIn else { return }
        guard let executable = executableOverride ?? ExecutableLocator.find("claude") else { throw BobError.message("Install Claude Code first, then reconnect.") }
        isSigningIn = true; error = nil
        defer { isSigningIn = false; loginTask = nil }
        let task = Task { [self] in
            defer { loginTerminal.stop() }
            try loginTerminal.start(executable: executable, arguments: ["auth", "login", "--claudeai"],
                directory: FileManager.default.homeDirectoryForCurrentUser.path, environment: ClaudeCodeBackend.environment)
            let deadline = Date().addingTimeInterval(180)
            while loginTerminal.running {
                try Task.checkCancellation()
                guard Date() < deadline else { throw BobError.message("Claude sign-in timed out. Try again.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard loginTerminal.exitStatus == 0 else { throw BobError.message("Claude sign-in did not finish. Try again.") }
        }
        loginTask = task
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        await refresh()
        guard isConnected else { throw BobError.message(error ?? "Claude Code is not signed in.") }
    }
    func cancelSignIn() { loginTask?.cancel() }
}
