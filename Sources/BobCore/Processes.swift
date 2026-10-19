import Foundation
import Darwin

public enum ExecutableLocator {
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = ([env["PATH"] ?? ""] + extra).joined(separator: ":")
        return env
    }
    public static func find(_ name: String, override: String = "") -> URL? {
        let manager = FileManager.default
        if !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return manager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first(where: { manager.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

public struct ProcessResult {
    public let status: Int32
    public let output: String
    public let error: String
}

public enum ProcessRunner {
    /// Reads both pipes concurrently; neither can block a child with a full buffer.
    public static func run(_ executable: URL, arguments: [String], directory: URL? = nil, timeout: TimeInterval = 15, environment: [String: String]? = nil) async throws -> ProcessResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe(), error = Pipe()
                process.executableURL = executable; process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = environment ?? ExecutableLocator.environment
                process.standardOutput = output; process.standardError = error
                process.standardInput = FileHandle.nullDevice
                control.attach(process)
                guard !control.cancelled else { continuation.resume(throwing: CancellationError()); return }
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                control.didStart()
                if control.cancelled { control.cancel() }
                let limit = DispatchWorkItem { control.signal(SIGTERM) }
                let killLimit = DispatchWorkItem { control.signal(SIGKILL) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: killLimit)
                let group = DispatchGroup()
                let capture = ProcessCapture()
                group.enter()
                DispatchQueue.global().async {
                    capture.output = boundedRead(output.fileHandleForReading); group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    capture.error = boundedRead(error.fileHandleForReading); group.leave()
                }
                process.waitUntilExit(); group.wait(); limit.cancel(); killLimit.cancel()
                control.finish()
                guard !control.cancelled else { continuation.resume(throwing: CancellationError()); return }
                continuation.resume(returning: ProcessResult(status: process.terminationStatus,
                    output: String(decoding: capture.output, as: UTF8.self), error: String(decoding: capture.error, as: UTF8.self)))
            }
          }
        }, onCancel: { control.cancel() })
    }
    private static func boundedRead(_ handle: FileHandle) -> Data {
        var result = Data(), truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            result.append(chunk)
            if result.count > 1024 * 1024 { result = Data(result.suffix(1024 * 1024)); truncated = true }
        }
        return truncated ? Data("[Earlier output truncated]\n".utf8) + result : result
    }
}

final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false
    private var processGroup: pid_t?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
    func attach(_ process: Process) { lock.lock(); self.process = process; lock.unlock() }
    func didStart() {
        lock.lock(); defer { lock.unlock() }
        if let process, getpgid(process.processIdentifier) == process.processIdentifier { processGroup = process.processIdentifier }
    }
    func finish() { lock.lock(); process = nil; processGroup = nil; lock.unlock() }
    func signal(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        if let processGroup { kill(-processGroup, value) }
        else if let process, process.isRunning { kill(process.processIdentifier, value) }
    }
    func cancel() {
        lock.lock(); isCancelled = true; lock.unlock()
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.signal(SIGKILL) }
    }
}

private final class ProcessCapture: @unchecked Sendable {
    var output = Data()
    var error = Data()
}
