import Foundation
import CoreServices
import XCTest
@testable import Bob

@MainActor final class ProjectFileIndexTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-index-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("text".utf8).write(to: url)
    }

    private func expect(_ paths: [String], for query: String, in model: CommandPaletteModel,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            await model.search(query)
            if model.matches.map(\.relativePath) == paths, !model.isIndexing { return }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        XCTFail("Expected \(paths), received \(model.matches.map(\.relativePath)); error: \(model.error ?? "none")", file: file, line: line)
    }

    func testOpeningPaletteReusesPreparedProjectIndex() async throws {
        let root = try fixture(), model = CommandPaletteModel()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        try write("Sources/One.swift", in: root)
        model.start(projectPath: root.path)
        await model.load(projectPath: root.path)
        XCTAssertNil(model.error)
        let generation = model.generation
        await model.load(projectPath: root.path)
        XCTAssertEqual(model.generation, generation, "Reopening must not rescan the project")
        await model.search("one")
        XCTAssertEqual(model.matches.map(\.relativePath), ["Sources/One.swift"])
    }

    func testNativeWatcherDeliversChanges() async throws {
        let root = try fixture()
        let changed = expectation(description: "Native file event")
        let watcher = try ProjectFileWatcher(root: root.path) { paths in
            if paths.contains("") || paths.contains("New.swift") { changed.fulfill() }
        }
        defer { watcher.stop(); try? FileManager.default.removeItem(at: root) }
        try write("New.swift", in: root)
        await fulfillment(of: [changed], timeout: 5)
    }

    func testWatcherIgnoresContentAndExcludedChangesAndRecoversFromLostEvents() {
        let root = "/project"
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        XCTAssertEqual(ProjectFileWatcher.changedPaths(root: root,
            paths: ["/project/Sources/New.swift", "/project/Sources/Existing.swift", "/project/node_modules/pkg/index.js", "/project-other/Outside.swift"],
            flags: [created, modified, created, created]), ["Sources/New.swift"])
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged] {
            XCTAssertEqual(ProjectFileWatcher.changedPaths(root: root, paths: [root], flags: [FSEventStreamEventFlags(flag)]), [""])
        }
        XCTAssertEqual(ProjectFileWatcher.changedPaths(root: root,
            paths: (0..<300).map { "/project/File\($0).swift" }, flags: Array(repeating: created, count: 300)), [""])
    }

    func testFilesystemEventsUpdateCachedIndexWhilePaletteIsClosed() async throws {
        let root = try fixture(), model = CommandPaletteModel()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        try write("Sources/One.swift", in: root)
        await model.load(projectPath: root.path)
        XCTAssertNil(model.error)
        try write("Sources/Nested/Two.swift", in: root)
        try await expect(["Sources/Nested/Two.swift"], for: "two.swift", in: model)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Sources/Nested"), to: root.appendingPathComponent("Renamed"))
        try await expect(["Renamed/Two.swift"], for: "two.swift", in: model)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Renamed"))
        try await expect([], for: "two.swift", in: model)
        try write("node_modules/pkg/Invisible.swift", in: root)
        await model.search("invisible")
        XCTAssertTrue(model.matches.isEmpty)
    }

    func testSwitchingProjectAndStoppingRejectOldIndexAndSearchResults() async throws {
        let first = try fixture(), second = try fixture(), model = CommandPaletteModel()
        defer { model.stop(); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try write("Old.swift", in: first); try write("New.swift", in: second)
        model.start(projectPath: first.path)
        await model.load(projectPath: second.path)
        await model.search("swift")
        XCTAssertEqual(model.matches.map(\.relativePath), ["New.swift"])
        let pending = Task { await model.search("new") }
        await Task.yield()
        model.stop()
        await pending.value
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertFalse(model.isIndexing)
        XCTAssertFalse(model.isSearching)
    }
}
