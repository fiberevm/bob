import XCTest
@testable import BobCore
@testable import Bob

final class FileDiffTests: XCTestCase {
    func testDiffPreservesLineNumbersUnicodeAndMissingFinalNewline() async throws {
        let diff = try await FileDiff.compare(before: "one\nold 🙂\nthree\n", after: "one\nnew 🙂\nthree\nlast")
        XCTAssertEqual(diff.addedCount, 2)
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.lines.filter { $0.kind == .added }.map(\.text), ["new 🙂", "last"])
        XCTAssertEqual(diff.lines.filter { $0.kind == .added }.compactMap(\.newNumber), [2, 4])
        XCTAssertEqual(diff.lines.first { $0.kind == .removed }?.oldNumber, 2)
        XCTAssertTrue(diff.lines.contains { $0.kind == .note && $0.text.contains("No newline") })
        let unchanged = try await FileDiff.compare(before: "same\n", after: "same\n")
        XCTAssertTrue(unchanged.lines.isEmpty)
    }

    func testDiffHandlesNewDeletedAndHeaderLikeContents() async throws {
        let added = try await FileDiff.compare(before: "", after: "\nhello\n")
        XCTAssertEqual(added.lines.filter { $0.kind == .added }.map(\.text), ["", "hello"])
        XCTAssertEqual(added.lines.filter { $0.kind == .added }.compactMap(\.newNumber), [1, 2])
        let deleted = try await FileDiff.compare(before: "gone\n", after: "")
        XCTAssertEqual(deleted.removedCount, 1)
        XCTAssertEqual(deleted.lines.first { $0.kind == .removed }?.oldNumber, 1)
        let headers = try await FileDiff.compare(before: "-- old\n", after: "++ new\n")
        XCTAssertEqual(headers.lines.first { $0.kind == .removed }?.text, "-- old")
        XCTAssertEqual(headers.lines.first { $0.kind == .added }?.text, "++ new")
    }

    func testStatusParserKeepsExactPathsAndConsumesRenameSourcesOutsideProject() {
        let output = "R  elsewhere/new.swift\0elsewhere/old.swift\0 M app/space \"🙂\".swift\0R  app/new\nname.swift\0app/old.swift\0?? app/untracked.swift\0UU app/conflict.swift\0 D app/deleted.swift\0"
        let changes = GitFileChange.parse(output, repository: URL(fileURLWithPath: "/repo"), project: URL(fileURLWithPath: "/repo/app"))
        XCTAssertEqual(changes.map(\.kind), [.modified, .renamed, .untracked, .conflicted, .deleted])
        XCTAssertEqual(changes[0].path, "/repo/app/space \"🙂\".swift")
        XCTAssertEqual(changes[1].path, "/repo/app/new\nname.swift")
        XCTAssertEqual(changes[1].originalPath, "/repo/app/old.swift")
    }
}

@MainActor final class FileChangeIntegrationTests: XCTestCase {
    private func git(_ arguments: [String], in root: URL) async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Bob Tests", "-c", "user.email=bob@example.invalid"] + arguments, directory: root)
        XCTAssertEqual(result.status, 0, result.error)
    }
    private func fixture(commit: Bool = true) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-file-changes-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Deleted"), withIntermediateDirectories: true)
        try Data("before\n".utf8).write(to: root.appendingPathComponent("Sources/file.swift"))
        try Data("removed\n".utf8).write(to: root.appendingPathComponent("Sources/Deleted/old.swift"))
        try Data("rename me\n".utf8).write(to: root.appendingPathComponent("rename.swift"))
        try await git(["init", "-q"], in: root)
        if commit {
            try await git(["add", "."], in: root)
            try await git(["commit", "-qm", "Initial"], in: root)
        }
        return root
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Workspace refresh did not finish")
    }

    func testGitChangesIncludeStagedUnstagedRenamedDeletedAndUntrackedFiles() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("after\n".utf8).write(to: root.appendingPathComponent("Sources/file.swift"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Deleted"))
        try Data("added\n".utf8).write(to: root.appendingPathComponent("added.swift"))
        try await git(["add", "added.swift"], in: root)
        try await git(["mv", "rename.swift", "new name.swift"], in: root)
        let untracked = "quote \" and\nnewline.swift"
        try Data("new\n".utf8).write(to: root.appendingPathComponent(untracked))
        let state = try await GitService.inspect(directory: root)
        let changes = Dictionary(uniqueKeysWithValues: state.changes.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.kind) })
        XCTAssertEqual(changes["file.swift"], .modified)
        XCTAssertEqual(changes["old.swift"], .deleted)
        XCTAssertEqual(changes["added.swift"], .added)
        XCTAssertEqual(changes["new name.swift"], .renamed)
        XCTAssertEqual(changes[untracked], .untracked)
        let original = try await GitService.originalText(path: root.appendingPathComponent("rename.swift").path, repository: root, revision: try XCTUnwrap(state.revision))
        XCTAssertEqual(original, "rename me\n")
        let nested = try await GitService.inspect(directory: root.appendingPathComponent("Sources"))
        XCTAssertEqual(Set(nested.changes.map(\.path)), Set(state.changes.filter { $0.path.hasPrefix(root.appendingPathComponent("Sources").path + "/") }.map(\.path)))
    }

    func testRepositoryWithoutCommitsStillShowsNewFiles() async throws {
        let root = try await fixture(commit: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["add", "Sources/file.swift"], in: root)
        let state = try await GitService.inspect(directory: root)
        XCTAssertTrue(state.isRepository)
        XCTAssertNil(state.revision)
        XCTAssertEqual(state.changes.first { $0.path == root.appendingPathComponent("Sources/file.swift").path }?.kind, .added)
        XCTAssertTrue(state.changes.contains { $0.kind == .untracked })
    }

    func testRefreshUpdatesCleanBuffersAndPreservesUnsavedEdits() async throws {
        let root = try await fixture()
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent(".state"))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await waitFor { store.git.revision != nil }
        let file = root.appendingPathComponent("Sources/file.swift")
        _ = try await store.openFileTab(file.path)
        try Data("after\n".utf8).write(to: file)
        store.refresh()
        try await waitFor { store.editorOriginal == "after\n" }
        XCTAssertEqual(store.fileChanges[file.path], .modified)
        let original = try await store.comparisonBase(for: file.path, fallback: store.editorOriginal)
        XCTAssertEqual(original.text, "before\n")
        store.editorText = "unsaved\n"
        try Data("external\n".utf8).write(to: file)
        try await git(["add", "Sources/file.swift"], in: root)
        store.refresh()
        try await waitFor { store.git.status.contains("M  Sources/file.swift") }
        XCTAssertEqual(store.editorText, "unsaved\n")
        XCTAssertEqual(store.editorOriginal, "after\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Deleted"))
        store.refresh()
        let deleted = root.appendingPathComponent("Sources/Deleted/old.swift").path
        try await waitFor { store.fileChanges[deleted] == .deleted }
        _ = try await store.openFileTab(deleted)
        XCTAssertEqual(store.editorText, "")
        let deletedOriginal = try await store.comparisonBase(for: deleted, fallback: "")
        XCTAssertEqual(deletedOriginal.text, "removed\n")
        XCTAssertTrue(store.hasUnsavedEdits)
    }

    func testNonRepositoryUsesTheEarliestRetainedBobCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-checkpoint-diff-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.swift")
        try Data("original\n".utf8).write(to: file)
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let files = store.fileService(path: root.path)
        try await files.write(file.path, text: "first edit\n", expected: "original\n")
        try await files.write(file.path, text: "second edit\n", expected: "first edit\n")
        store.refresh()
        try await waitFor { store.checkpoints.count == 2 }
        let base = try await store.comparisonBase(for: file.path, fallback: "second edit\n")
        XCTAssertEqual(base.text, "original\n")
        XCTAssertEqual(base.label, "Before Bob edits")
        XCTAssertEqual(store.fileChanges[file.path], .modified)
        try await files.write(file.path, text: "original\n", expected: "second edit\n")
        store.refresh()
        try await waitFor { store.checkpoints.count == 3 }
        XCTAssertNil(store.fileChanges[file.path])
    }
}
