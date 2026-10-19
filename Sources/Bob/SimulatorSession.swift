import AppKit
import Combine
import BobCore

struct SimulatorDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let runtime: String
    let state: String
    var isBooted: Bool { state == "Booted" }
    var label: String { "\(name) · \(runtime)" }

    static func decode(_ data: Data) throws -> [Self] {
        struct Listing: Decodable { let devices: [String: [Device]] }
        struct Device: Decodable {
            let udid: String, name: String, state: String
            let isAvailable: Bool?
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        return listing.devices.flatMap { runtime, devices -> [Self] in
            guard runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") else { return [] }
            let version = "iOS " + runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.iOS-", with: "").replacingOccurrences(of: "-", with: ".")
            return devices.filter { $0.isAvailable == true && UUID(uuidString: $0.udid) != nil }.map {
                Self(id: $0.udid, name: $0.name, runtime: version, state: $0.state)
            }
        }.sorted {
            if $0.isBooted != $1.isBooted { return $0.isBooted }
            if $0.runtime != $1.runtime { return $0.runtime.compare($1.runtime, options: .numeric) == .orderedDescending }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

typealias SimulatorCommand = @Sendable (String, [String], TimeInterval) async throws -> String

/// Device state belongs to this project. Opening a tab only lists devices;
/// booting, shutting down, and installing are explicit user actions.
@MainActor final class SimulatorSession: ObservableObject {
    @Published private(set) var devices: [SimulatorDevice] = []
    @Published private(set) var selectedID = ""
    @Published private(set) var connectedID: String?
    @Published private(set) var developerDirectory = ""
    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published var error: String?
    private let command: SimulatorCommand
    private var operation: Task<Void, Never>?
    private var generation = 0
    weak var display: SimulatorScreenView?
    var selected: SimulatorDevice? { devices.first { $0.id == selectedID } }

    init(command: @escaping SimulatorCommand = { try await SimulatorSession.run($0, $1, $2) }) { self.command = command }

    nonisolated static func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> String {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: executable), arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BobError.message(detail.isEmpty ? "The simulator command failed (\(result.status))." : detail)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func select(_ id: String) {
        guard !busy, devices.contains(where: { $0.id == id }), selectedID != id else { return }
        connectedID = nil; selectedID = id; error = nil
    }

    func refresh() {
        perform("Loading devices…") { token in
            let directory = try await self.command("/usr/bin/xcode-select", ["-p"], 10)
            try self.check(token)
            guard FileManager.default.fileExists(atPath: directory + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit") else {
                throw BobError.message("Install Xcode and select it in Xcode Settings → Locations → Command Line Tools.")
            }
            self.developerDirectory = directory
            try await self.loadDevices(token)
        }
    }

    func connect() {
        guard let device = selected else { return }
        connectedID = nil
        perform("Starting \(device.name)…") { token in
            try await self.loadDevices(token)
            guard let current = self.devices.first(where: { $0.id == device.id }) else { throw BobError.message("This simulator is no longer available. Choose another device.") }
            if !current.isBooted { _ = try await self.simctl(["boot", device.id], timeout: 30) }
            try self.check(token)
            _ = try await self.simctl(["bootstatus", device.id, "-b"], timeout: 180)
            try self.check(token)
            try await self.loadDevices(token)
            try self.check(token)
            self.connectedID = device.id
        }
    }

    func shutdownDevice() {
        guard let device = selected else { return }
        connectedID = nil
        perform("Shutting down \(device.name)…") { token in
            _ = try await self.simctl(["shutdown", device.id], timeout: 30)
            try self.check(token)
            try await self.loadDevices(token)
        }
    }

    func chooseApp() {
        guard connectedID != nil, !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Install Simulator App"
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installApp(url)
    }

    func installApp(_ url: URL) {
        guard let id = connectedID else { return }
        perform("Installing \(url.deletingPathExtension().lastPathComponent)…") { token in
            let infoURL = url.appendingPathComponent("Info.plist")
            let data = try Data(contentsOf: infoURL)
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
                  let platforms = info["CFBundleSupportedPlatforms"] as? [String], platforms.contains("iPhoneSimulator") else {
                throw BobError.message("Choose an iOS Simulator .app build. Device and Mac apps cannot run here.")
            }
            try self.check(token)
            _ = try await self.simctl(["install", id, url.path], timeout: 120)
            try self.check(token)
            _ = try await self.simctl(["launch", id, bundleID], timeout: 30)
            try self.check(token)
        }
    }

    func disconnect() { display?.detach(); connectedID = nil }

    func cancel() {
        generation += 1; operation?.cancel(); operation = nil
        busy = false; activity = ""
    }

    /// Detach only; devices are shared with Xcode and must not be stopped by closing a tab.
    func close() { cancel(); disconnect() }

    private func perform(_ activity: String, work: @escaping @MainActor (Int) async throws -> Void) {
        guard !busy else { return }
        generation += 1
        let token = generation
        busy = true; self.activity = activity; error = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.busy = false; self.activity = ""; self.operation = nil } }
            do { try await work(token) }
            catch is CancellationError {}
            catch { if token == self.generation { self.error = error.localizedDescription } }
        }
    }

    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func simctl(_ arguments: [String], timeout: TimeInterval = 15) async throws -> String {
        try await command("/usr/bin/xcrun", ["simctl"] + arguments, timeout)
    }

    private func loadDevices(_ token: Int) async throws {
        let json = try await simctl(["list", "devices", "available", "--json"])
        try check(token)
        let updated = try SimulatorDevice.decode(Data(json.utf8))
        devices = updated
        if !updated.contains(where: { $0.id == selectedID }) { connectedID = nil; selectedID = updated.first?.id ?? "" }
        if let connectedID, !updated.contains(where: { $0.id == connectedID && $0.isBooted }) { self.connectedID = nil }
    }
}
