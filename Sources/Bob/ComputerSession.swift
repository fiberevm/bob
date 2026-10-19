import AppKit
import ApplicationServices
import Combine
import BobCore

struct ComputerPermissions: Equatable {
    let screenRecording: Bool
    let accessibility: Bool
}

@MainActor protocol ComputerDriver: AnyObject {
    var permissions: ComputerPermissions { get }
    var onUserInput: (() -> Void)? { get set }
    func applications() -> [ComputerApp]
    func application(_ bundleID: String) throws -> ComputerApp
    func open(_ bundleID: String) async throws -> ComputerApp
    func capture(_ app: String, windowID: UInt32?) async throws -> ComputerSnapshot
    func perform(_ action: ComputerAction, in snapshot: ComputerSnapshot) async throws
    func cancel()
}

@MainActor protocol AgentComputer: AnyObject {
    var enabled: Bool { get }
    var permissionRevision: Int { get }
    func appsDescription() -> String
    func application(_ bundleID: String) throws -> ComputerApp
    func isAlwaysAllowed(_ app: String) -> Bool
    func remember(_ app: String)
    func open(_ app: String) async throws -> ToolResult
    func capture(_ app: String, windowID: UInt32?) async throws -> ComputerSnapshot
    func current(_ id: String) throws -> ComputerSnapshot
    func perform(_ action: ComputerAction) async throws -> ToolResult
    func cancel()
}

@MainActor final class ComputerAccess: ObservableObject {
    static let shared = ComputerAccess()
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "computer.enabled") } }
    @Published private(set) var allowedApps: Set<String>
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "computer.enabled")
        allowedApps = Set(defaults.stringArray(forKey: "computer.allowedApps") ?? []).filter { !ComputerAppPolicy.isBlocked($0) }
    }
    func allow(_ app: String) {
        guard !ComputerAppPolicy.isBlocked(app) else { return }
        allowedApps.insert(app); save()
    }
    func revoke(_ app: String) { allowedApps.remove(app); save() }
    private func save() { defaults.set(allowedApps.sorted(), forKey: "computer.allowedApps") }
}

@MainActor final class ComputerSession: ObservableObject, AgentComputer {
    let access: ComputerAccess
    private let driver: any ComputerDriver
    @Published private(set) var applications: [ComputerApp] = []
    @Published private(set) var permissions = ComputerPermissions(screenRecording: false, accessibility: false)
    @Published private(set) var latest: ComputerSnapshot?
    @Published private(set) var busy = false
    @Published var error: String?
    var onAgentUse: (() -> Void)?
    var onTakeover: (() -> Void)?
    private var snapshot: ComputerSnapshot?
    private var generation = 0
    private(set) var permissionRevision = 0
    private var observation: AnyCancellable?
    init(access: ComputerAccess? = nil, driver: (any ComputerDriver)? = nil) {
        self.access = access ?? .shared; self.driver = driver ?? NativeComputerDriver()
        self.driver.onUserInput = { [weak self] in self?.cancel(); self?.onTakeover?() }
        observation = self.access.objectWillChange.sink { [weak self] in
            // A permission edit revokes any in-flight snapshot/action lease across project windows.
            self?.permissionRevision += 1; self?.cancel(); self?.latest = nil; self?.objectWillChange.send()
        }
    }
    var enabled: Bool { access.enabled }
    func refresh() { applications = driver.applications(); permissions = driver.permissions }
    func requestScreenRecording() { CGRequestScreenCaptureAccess(); refresh() }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options); refresh()
    }
    func openPermissionSettings(_ accessibility: Bool) {
        let anchor = accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
    func appsDescription() -> String {
        refresh()
        return "Computer use: \(enabled ? "enabled" : "disabled; enable it in the Computer panel"). Screen Recording: \(permissions.screenRecording). Accessibility: \(permissions.accessibility).\n" + applications.map { "\($0.name) · \($0.bundleID)" }.joined(separator: "\n")
    }
    func application(_ bundleID: String) throws -> ComputerApp {
        guard !ComputerAppPolicy.isBlocked(bundleID) else { throw BobError.message("This app requires manual interaction and cannot be used by the agent.") }
        return try driver.application(bundleID)
    }
    func isAlwaysAllowed(_ app: String) -> Bool { access.allowedApps.contains(app) && !ComputerAppPolicy.isBlocked(app) }
    func remember(_ app: String) { access.allow(app) }
    private func begin(_ app: String) throws -> Int {
        guard enabled else { throw BobError.message("Enable computer use in the Computer panel first.") }
        _ = try application(app)
        guard !busy else { throw BobError.message("A computer operation is already running.") }
        try Task.checkCancellation()
        busy = true; error = nil; onAgentUse?()
        return generation
    }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard enabled, token == generation else { throw CancellationError() }
    }
    func open(_ app: String) async throws -> ToolResult {
        let token = try begin(app); defer { busy = false }
        let opened = try await driver.open(app)
        try check(token); refresh()
        return ToolResult(text: "Opened \(opened.name) (\(opened.bundleID)). Capture its window before acting.")
    }
    func capture(_ app: String, windowID: UInt32? = nil) async throws -> ComputerSnapshot {
        let token = try begin(app); defer { busy = false }
        snapshot = nil
        let state = try await driver.capture(app, windowID: windowID)
        try check(token)
        snapshot = state; latest = state; permissions = driver.permissions
        return state
    }
    func current(_ id: String) throws -> ComputerSnapshot {
        guard enabled, let snapshot, snapshot.id == id else { throw BobError.message("Stale computer snapshot. Capture fresh app state.") }
        return snapshot
    }
    func perform(_ action: ComputerAction) async throws -> ToolResult {
        let state = try current(action.snapshot)
        try action.validate(in: state)
        let token = try begin(state.app.bundleID); defer { busy = false }
        snapshot = nil // Every action consumes its observation, including failed/uncertain actions.
        try await driver.perform(action, in: state)
        try check(token)
        do {
            try await Task.sleep(for: .milliseconds(160))
            let next = try await driver.capture(state.app.bundleID, windowID: state.windowID)
            try check(token)
            snapshot = next; latest = next
            return next.result
        } catch is CancellationError { throw CancellationError() }
        catch { return ToolResult(text: "The action was dispatched. A fresh snapshot is unavailable: \(error.localizedDescription). Inspect app state before repeating the action.") }
    }
    func cancel() { generation += 1; snapshot = nil; driver.cancel() }
    func close() { cancel(); latest = nil; onAgentUse = nil; onTakeover = nil; driver.onUserInput = nil }
}
