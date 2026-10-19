import XCTest
@testable import Bob
@testable import BobCore

@MainActor final class FileTreeMutationTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let root: URL
        let trash: URL
        let store: AppStore
        @MainActor func cleanup() { store.shutdown(); try? FileManager.default.removeItem(at: base) }
    }
    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bob-file-mutations-\(UUID())")
        let root = base.appendingPathComponent("Project"), trash = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("let one = 1".utf8).write(to: root.appendingPathComponent("Sources/One.swift"))
        try Data("let two = 2".utf8).write(to: root.appendingPathComponent("Sources/Nested/Two.swift"))
        try Data("read me".utf8).write(to: root.appendingPathComponent("README.md"))
        let canonical = root.resolvingSymlinksInPath()
        let store = AppStore(projectPath: canonical.path, storageDirectory: base.appendingPathComponent("State"), trashItem: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        return Fixture(base: base, root: canonical, trash: trash, store: store)
    }

    func testCreateRevealsNestedItemsAndOpensNewFileWithoutReplacingUnsavedBuffer() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let first = try await f.store.openFileTab("README.md")
        f.store.editorText = "unsaved readme"
        try await f.store.createFileTreeItem(named: "Features", in: f.root.appendingPathComponent("Sources").path, isDirectory: true)
        let folder = f.root.appendingPathComponent("Sources/Features")
        XCTAssertTrue(f.store.fileTree.expandedPaths.contains(folder.path))
        XCTAssertTrue(f.store.fileTree.rows.contains { $0.entry.path == folder.path && $0.depth == 1 })
        try await f.store.createFileTreeItem(named: "New.swift", in: folder.path, isDirectory: false)
        XCTAssertEqual(f.store.editorPath, folder.appendingPathComponent("New.swift").path)
        XCTAssertEqual(f.store.editorText, "")
        XCTAssertEqual(f.store.buffer(for: first)?.text, "unsaved readme")
        XCTAssertNotNil(f.store.editorFocusRequest)
        XCTAssertTrue(f.store.fileTree.rows.contains { $0.entry.name == "New.swift" && $0.depth == 2 })
        XCTAssertFalse(f.store.isMutatingFiles)
    }

    func testFolderRenameRemapsOpenBuffersExpansionsAndCheckpoints() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let first = try await f.store.openFileTab("Sources/One.swift")
        f.store.editorText = "unsaved one"
        let second = try await f.store.openFileTab("Sources/Nested/Two.swift")
        f.store.editorText = "unsaved two"
        let source = f.root.appendingPathComponent("Sources"), destination = f.root.appendingPathComponent("Renamed")
        try await f.store.fileTree.reveal(FileEntry(path: source.appendingPathComponent("Nested").path, name: "Nested", isDirectory: true))
        let files = f.store.fileService(path: f.root.path)
        try await files.write("Sources/One.swift", text: "let one = 3", expected: "let one = 1")
        f.store.openPanel(.changes)
        let selected = f.store.selectedTabID
        try await f.store.renameFileTreeItem(source.path, to: "Renamed")
        XCTAssertEqual(f.store.selectedTabID, selected)
        XCTAssertEqual(f.store.buffer(for: first)?.path, destination.appendingPathComponent("One.swift").path)
        XCTAssertEqual(f.store.buffer(for: first)?.text, "unsaved one")
        XCTAssertEqual(f.store.buffer(for: second)?.path, destination.appendingPathComponent("Nested/Two.swift").path)
        XCTAssertEqual(f.store.editorText, "unsaved two")
        XCTAssertTrue(f.store.fileTree.expandedPaths.contains(destination.appendingPathComponent("Nested").path))
        XCTAssertFalse(f.store.fileTree.expandedPaths.contains(source.path))
        XCTAssertTrue(f.store.fileTree.rows.contains { $0.entry.name == "Two.swift" })
        let history = await files.history()
        XCTAssertEqual(history.first?.path, destination.appendingPathComponent("One.swift").path)
        _ = try await files.undo()
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("One.swift")), "let one = 1")
        f.store.selectTab(first)
        XCTAssertEqual(f.store.editorText, "unsaved one")
        let reused = try await f.store.openFileTab("Renamed/One.swift")
        XCTAssertEqual(reused, first)
    }

    func testRenameFilePreservesDirtyBufferAndChangesOnlyItsOwnPath() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let id = try await f.store.openFileTab("Sources/One.swift")
        f.store.editorText = "unsaved"
        try await f.store.renameFileTreeItem(f.root.appendingPathComponent("Sources/One.swift").path, to: "One.txt")
        XCTAssertEqual(f.store.selectedTabID, id)
        XCTAssertEqual(f.store.editorText, "unsaved")
        XCTAssertEqual(f.store.editorOriginal, "let one = 1")
        XCTAssertEqual(f.store.editorPath, f.root.appendingPathComponent("Sources/One.txt").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Sources/One.swift").path))
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("Sources/One.txt")), "let one = 1")
        XCTAssertEqual(WorkspaceFiles.remap("/SourcesExtra/file", from: "/Sources", to: "/Renamed"), "/SourcesExtra/file")
    }

    func testTrashBlocksDirtyDescendantsThenClosesOnlyAffectedTabsAndRetainsFilesForRecovery() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let first = try await f.store.openFileTab("Sources/One.swift")
        f.store.editorText = "unsaved one"
        let second = try await f.store.openFileTab("Sources/Nested/Two.swift")
        f.store.editorText = "unsaved two"
        let unrelated = try await f.store.openFileTab("README.md")
        f.store.editorText = "unrelated unsaved"
        do { try await f.store.trashFileTreeItem(f.root.appendingPathComponent("Sources").path); XCTFail("Dirty descendants must block deletion") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unsaved")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Sources/One.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.trash.appendingPathComponent("Sources").path))
        XCTAssertFalse(f.store.isMutatingFiles)
        f.store.selectTab(first); f.store.editorText = f.store.editorOriginal
        f.store.selectTab(second); f.store.editorText = f.store.editorOriginal
        f.store.selectTab(unrelated)
        try await f.store.trashFileTreeItem(f.root.appendingPathComponent("Sources").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Sources").path))
        XCTAssertEqual(try String(contentsOf: f.trash.appendingPathComponent("Sources/Nested/Two.swift")), "let two = 2")
        XCTAssertEqual(f.store.openTabs.count, 1)
        XCTAssertEqual(f.store.selectedTabID, unrelated)
        XCTAssertEqual(f.store.editorText, "unrelated unsaved")
        XCTAssertFalse(f.store.fileTree.rows.contains { $0.entry.name == "Sources" })
    }

    func testTrashingLastOpenFileLeavesAnEmptyEditorAndPrunesItsUndoHistory() async throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try await f.store.openFileTab("README.md")
        let files = f.store.fileService(path: f.root.path)
        try await files.write("README.md", text: "changed", expected: "read me")
        try await f.store.trashFileTreeItem(f.root.appendingPathComponent("README.md").path)
        XCTAssertEqual(f.store.openTabs.map(\.kind), [.editor])
        XCTAssertNil(f.store.editorPath)
        XCTAssertEqual(f.store.editorText, "")
        let history = await files.history()
        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(f.store.fileTree.rows.contains { $0.entry.name == "README.md" })
    }

    func testInvalidNamesCollisionsAndProjectBoundaryLeaveExistingItemsUntouched() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let files = f.store.fileService(path: f.root.path)
        for name in ["", " ", ".", "..", "../escape", "a/b", "a:b", "a\nname", ".git"] {
            do { _ = try await files.createItem(named: name, in: f.root.path, isDirectory: false); XCTFail("Accepted invalid name: \(name)") } catch {}
        }
        for directory in [f.root.deletingLastPathComponent().path, f.root.appendingPathComponent(".git").path] {
            do { _ = try await files.createItem(named: "escape", in: directory, isDirectory: true); XCTFail("Accepted invalid parent") } catch {}
        }
        do { _ = try await files.createItem(named: "README.md", in: f.root.path, isDirectory: false); XCTFail("Overwrote existing file") } catch {}
        do { _ = try await files.renameItem("Sources", to: "README.md"); XCTFail("Replaced existing item") } catch {}
        do { _ = try await files.renameItem(f.root.path, to: "Project2"); XCTFail("Renamed project root") } catch {}
        do { _ = try await files.trashItemAtPath(f.root.path); XCTFail("Trashed project root") } catch {}
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("README.md")), "read me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Sources/One.swift").path))
    }

    func testCaseOnlyRenameWorksAndSymlinkOperationsActOnLinkInsteadOfTarget() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let files = f.store.fileService(path: f.root.path)
        _ = try await files.renameItem("README.md", to: "Readme.md")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains("Readme.md"))
        let target = f.root.appendingPathComponent("Sources")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("Alias"), withDestinationURL: target)
        _ = try await files.renameItem("Alias", to: "Alias2")
        _ = try await files.trashItemAtPath("Alias2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("One.swift").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.trash.appendingPathComponent("Alias2").path), target.path)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("Escape"), withDestinationURL: f.trash)
        do { _ = try await files.createItem(named: "outside", in: "Escape", isDirectory: false); XCTFail("Created outside project through symlink") } catch {}
        _ = try await files.trashItemAtPath("Escape")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.trash.path))
    }

    func testTrashFailurePreservesFileTabsAndCheckpoints() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let failing = AppStore(projectPath: f.root.path, storageDirectory: f.base.appendingPathComponent("FailingState"),
                               trashItem: { _ in throw BobError.message("Trash is unavailable.") })
        defer { failing.shutdown() }
        let tab = try await failing.openFileTab("README.md")
        let files = failing.fileService(path: f.root.path)
        try await files.write("README.md", text: "changed", expected: "read me")
        do { try await failing.trashFileTreeItem(f.root.appendingPathComponent("README.md").path); XCTFail("Expected Trash failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Trash is unavailable.") }
        XCTAssertEqual(failing.selectedTabID, tab)
        XCTAssertEqual(failing.editorPath, f.root.appendingPathComponent("README.md").path)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("README.md")), "changed")
        let history = await files.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertFalse(failing.isMutatingFiles)
    }
}
