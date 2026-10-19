import XCTest
import Darwin
@testable import BobCore
@testable import Bob

@MainActor final class CommandExecutionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-command-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func run(_ command: String, project: URL) async throws -> String {
        let approvals = ApprovalCoordinator(runID: UUID()) { request in
            if let request { XCTFail("Routine command unexpectedly requested approval"); request.resolve(false) }
        }
        let tools = AgentTools(files: WorkspaceFiles(root: project, checkpointDirectory: project.appendingPathComponent("checkpoints")),
            project: project.path, browser: nil, reviewer: FixtureToolSafetyReviewer(.init(risk: .low, reason: "Local test fixture")),
            approvals: approvals, rootInstructions: "")
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["command": command]), as: UTF8.self)
        return try await tools.registry.perform(.init(id: UUID().uuidString, name: "run_command", arguments: arguments)).text
    }

    func testCommandsUseRealHomeAndCanAccessHostFilesOutsideProject() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), outside = root.appendingPathComponent("host-file.txt")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "host content".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("host-link"), withDestinationURL: outside)
        let result = try await run("""
        test "$HOME" = \(quote(FileManager.default.homeDirectoryForCurrentUser.path)) &&
        test "$PWD" -ef \(quote(project.path)) &&
        /bin/sh -c 'cat host-link' &&
        printf changed > \(quote(outside.path)) &&
        printf linked > host-link &&
        printf project > inside.txt
        """, project: project)
        XCTAssertTrue(result.hasPrefix("Exit: 0\n"), result)
        XCTAssertTrue(result.contains("host content"), result)
        XCTAssertEqual(try String(contentsOf: outside), "linked")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("inside.txt")), "project")
    }

    func testCommandsCanConnectToLocalServersWithoutNetworkGrant() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EPERM) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
        let result = try await run("/usr/bin/nc -z -w 1 127.0.0.1 \(UInt16(bigEndian: address.sin_port))", project: root)
        XCTAssertTrue(result.hasPrefix("Exit: 0\n"), result)
    }

    func testCommandsCanStartTmuxSessions() async throws {
        guard let tmux = ExecutableLocator.find("tmux") else { throw XCTSkip("tmux is not installed.") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let socket = "/private/tmp/bob-tmux-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socket) }
        let control = quote(tmux.path) + " -S " + quote(socket)
        let result = try await run("""
        trap \(quote(control + " kill-server >/dev/null 2>&1")) EXIT
        \(control) new-session -d -s fixture /bin/sleep 5 &&
        \(control) display-message -p -t fixture '#{session_name}'
        """, project: root)
        XCTAssertTrue(result.hasPrefix("Exit: 0\n"), result)
        XCTAssertTrue(result.contains("fixture"), result)
    }
}
