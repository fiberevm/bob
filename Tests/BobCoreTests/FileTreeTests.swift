import XCTest
@testable import Bob
@testable import BobCore

@MainActor final class FileTreeTests: XCTestCase {
    private func fixture() throws -> (URL, FileTree) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-tree-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
        try Data("let value = 1".utf8).write(to: root.appendingPathComponent("Sources/Nested/File.swift"))
        try Data("Read me".utf8).write(to: root.appendingPathComponent("README.md"))
        let tree = FileTree()
        tree.reset(files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent(".checkpoints")))
        return (root, tree)
    }

    func testFoldersExpandInlineAndRememberNestedExpansionAfterCollapse() async throws {
        let (root, tree) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await tree.refresh()
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["Sources", "README.md"])
        let sources = try XCTUnwrap(tree.rows.first?.entry)
        try await tree.toggleFolder(sources)
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["Sources", "Nested", "README.md"])
        XCTAssertEqual(tree.rows.map(\.depth), [0, 1, 0])
        let nested = try XCTUnwrap(tree.rows.first { $0.entry.name == "Nested" }?.entry)
        try await tree.toggleFolder(nested)
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["Sources", "Nested", "File.swift", "README.md"])
        XCTAssertEqual(tree.rows.map(\.depth), [0, 1, 2, 0])
        try await tree.toggleFolder(sources)
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["Sources", "README.md"])
        try await tree.toggleFolder(sources)
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["Sources", "Nested", "File.swift", "README.md"])
        try await tree.toggleFolder(sources)
        try await tree.refresh()
        try await tree.toggleFolder(sources)
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["Sources", "Nested", "File.swift", "README.md"])
    }

    func testRefreshPreservesExpandedFoldersAndRemovesDeletedBranches() async throws {
        let (root, tree) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await tree.refresh()
        let sources = try XCTUnwrap(tree.rows.first?.entry)
        try await tree.toggleFolder(sources)
        let nested = try XCTUnwrap(tree.rows.first { $0.entry.name == "Nested" }?.entry)
        try await tree.toggleFolder(nested)
        try Data("new".utf8).write(to: root.appendingPathComponent("Sources/New.swift"))
        try await tree.refresh()
        XCTAssertTrue(tree.expandedPaths.contains(sources.path))
        XCTAssertTrue(tree.expandedPaths.contains(nested.path))
        XCTAssertTrue(tree.rows.contains { $0.entry.name == "New.swift" && $0.depth == 1 })
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources"))
        try await tree.refresh()
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["README.md"])
        XCTAssertTrue(tree.expandedPaths.isEmpty)
    }

    func testOpeningEmptyFolderAndResettingTree() async throws {
        let (root, tree) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try await tree.refresh()
        let empty = try XCTUnwrap(tree.rows.first { $0.entry.name == "Empty" }?.entry)
        try await tree.toggleFolder(empty)
        XCTAssertTrue(tree.expandedPaths.contains(empty.path))
        XCTAssertFalse(tree.rows.contains { $0.depth > 0 })
        tree.reset()
        XCTAssertTrue(tree.rows.isEmpty)
        XCTAssertTrue(tree.expandedPaths.isEmpty)
        XCTAssertTrue(tree.loadingPaths.isEmpty)
    }

    func testSymlinkToAncestorKeepsDistinctPathsWithoutRecursingAutomatically() async throws {
        let (root, tree) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Loop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        try await tree.refresh()
        try await tree.toggleFolder(FileEntry(path: link.path, name: "Loop", isDirectory: true))
        XCTAssertTrue(tree.rows.contains { $0.entry.path == link.appendingPathComponent("Sources").path && $0.depth == 1 })
        XCTAssertEqual(Set(tree.rows.map(\.id)).count, tree.rows.count)
        XCTAssertLessThan(tree.rows.count, 20)
    }

    func testDeletedFilesAndTheirMissingParentsStayVisibleUntilChangesClear() async throws {
        let (root, tree) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources"))
        tree.setChangedPaths([root.appendingPathComponent("Sources/Nested/File.swift").path])
        try await tree.refresh()
        let sources = try XCTUnwrap(tree.rows.first { $0.entry.name == "Sources" }?.entry)
        try await tree.toggleFolder(sources)
        let nested = try XCTUnwrap(tree.rows.first { $0.entry.name == "Nested" }?.entry)
        try await tree.toggleFolder(nested)
        XCTAssertTrue(tree.rows.contains { $0.entry.name == "File.swift" && $0.depth == 2 })
        try await tree.refresh()
        XCTAssertTrue(tree.rows.contains { $0.entry.name == "File.swift" })
        tree.setChangedPaths([])
        XCTAssertEqual(tree.rows.map { $0.entry.name }, ["README.md"])
    }
}
