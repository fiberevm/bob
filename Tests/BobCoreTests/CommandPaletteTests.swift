import AppKit
import SwiftUI
import XCTest
@testable import Bob
@testable import BobCore

final class ProjectFileSearchTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-search-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("text".utf8).write(to: url)
    }

    func testIndexIncludesNestedUntrackedAndHiddenFilesButSkipsGeneratedFolders() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["Sources/Nested/View.swift", "README.md", ".github/workflows/test.yml", ".gitignore", "New.txt"]
        for path in paths + [".git/config", ".build/debug/Bob", "node_modules/pkg/index.js", ".venv/bin/python", "Sources/.DS_Store"] {
            try write(path, in: root)
        }
        XCTAssertEqual(Set(try ProjectFileSearch.index(root: root).map(\.relativePath)), Set(paths))
    }

    func testIndexDoesNotFollowDirectoryLinksOrExposeExternalAndGitFileLinks() throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try write("Sources/View.swift", in: root)
        try write(".git/config", in: root)
        try write("Secret.txt", in: outside)
        let links: [(String, URL)] = [
            ("loop", root), ("external", outside), ("secret.txt", outside.appendingPathComponent("Secret.txt")),
            ("config.txt", root.appendingPathComponent(".git/config")),
            ("Alias.swift", root.appendingPathComponent("Sources/View.swift"))
        ]
        for (name, destination) in links {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: destination)
        }
        XCTAssertEqual(Set(try ProjectFileSearch.index(root: root).map(\.relativePath)), ["Sources/View.swift", "Alias.swift"])
    }

    func testSearchRanksExactFilenamesThenPrefixesAndSupportsPathsAndAbbreviations() throws {
        let paths = ["Tests/CommandPaletteTests.swift", "Sources/Bob/CommandPalette.swift", "Sources/Bob/CommandPaletteModel.swift", "README.md", "Docs/CommandPalette.swift/Notes.md"]
        let files = paths.map(ProjectFile.init)
        XCTAssertEqual(try ProjectFileSearch.search("commandpalette.swift", in: files).first?.relativePath, paths[1])
        XCTAssertEqual(try ProjectFileSearch.search("cpm", in: files).first?.name, "CommandPaletteModel.swift")
        XCTAssertEqual(try ProjectFileSearch.search("sources/bob/command", in: files).count, 2)
        XCTAssertEqual(try ProjectFileSearch.search("tests palette", in: files).first?.relativePath, paths[0])
        XCTAssertTrue(try ProjectFileSearch.search("nothing-matches", in: files).isEmpty)
        XCTAssertEqual(try ProjectFileSearch.search("", in: files, limit: 2).count, 2)
        XCTAssertTrue(try ProjectFileSearch.search("swift", in: files, limit: 0).isEmpty)
        XCTAssertNotNil(CommandSearch.score("cafe", title: "Café.swift"))
        XCTAssertNotNil(CommandSearch.score("nw cht", title: "New chat"))
    }

    func testIndexDoesNotTruncateLargeDirectoriesToTheFileTreeLimit() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2_005 { try write("File\(index).swift", in: root) }
        let files = try ProjectFileSearch.index(root: root)
        XCTAssertEqual(files.count, 2_005)
        XCTAssertEqual(try ProjectFileSearch.search("File2004.swift", in: files).first?.name, "File2004.swift")
    }

    func testTopTwentyMatchesAgreeWithFullRankingForSortedAndUnsortedInput() throws {
        let names = ["View", "Preview", "Viewport", "Value", "VividWave", "Other"]
        let files = (0..<500).reversed().map { index in
            ProjectFile(relativePath: "Feature\(index)/\(names[index % names.count]).swift")
        } + [ProjectFile(relativePath: "Last/view")]
        let index = ProjectFileSearch.Index(files: files)
        for query in ["view", "swift", "vw", "feature1 view", "missing"] {
            let expected = files.compactMap { file -> (ProjectFile, Int)? in
                CommandSearch.score(query, title: file.name, path: file.relativePath).map { (file, $0) }
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.relativePath.localizedStandardCompare($1.0.relativePath) == .orderedAscending
            }.prefix(20).map { $0.0 }
            XCTAssertEqual(try ProjectFileSearch.search(query, in: files), expected, query)
            XCTAssertEqual(try index.search(query), expected, query)
            XCTAssertEqual(try index.search(query, limit: 500), expected, "Requests cannot exceed twenty results")
            XCTAssertEqual(try index.search(query, limit: 3), Array(expected.prefix(3)), query)
        }
        XCTAssertEqual(try index.search("").count, 20)
        XCTAssertEqual(try index.search(" ", limit: 500).count, 20)
        XCTAssertEqual(try index.search("view").first?.relativePath, "Last/view", "An exact match beyond the first twenty candidates must win")
    }

    func testPreparedIndexPreservesAccentUnicodeAndMultiTokenMatching() throws {
        let files = ["Sources/Café.swift", "文档/视图.swift", "Icons/👩🏽‍💻-View.swift", "Sources/Cafe\u{301}Menu.swift", "Tests/NewChatTests.swift"].map(ProjectFile.init)
        let index = ProjectFileSearch.Index(files: files)
        XCTAssertEqual(try index.search(" CAFÉ.SWIFT \n").first?.relativePath, files[0].relativePath)
        XCTAssertEqual(try index.search("cafe m").first?.relativePath, files[3].relativePath)
        XCTAssertEqual(try index.search("文档 视").first?.relativePath, files[1].relativePath)
        XCTAssertEqual(try index.search("👩🏽‍💻 view").first?.relativePath, files[2].relativePath)
        XCTAssertEqual(try index.search("nw cht").first?.relativePath, files[4].relativePath)
        XCTAssertTrue(try index.search("文档 cafe").isEmpty)
    }

    func testIncrementalUpdatesReplaceOnlyAffectedSubtreesAndKeepNaturalOrder() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Sources/File2.swift", "Sources/File10.swift", "Keep/A.swift"] { try write(path, in: root) }
        let original = try ProjectFileSearch.Index(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/File2.swift"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("Sources/File10.swift"), to: root.appendingPathComponent("Sources/File3.swift"))
        try write("Sources/Nested/New.swift", in: root)
        try write("Keep/Unreported.swift", in: root)
        let partial = try original.updating(root: root, paths: ["Sources", "Sources/Nested/New.swift", "Sources"])
        XCTAssertEqual(partial.files.map(\.relativePath), ["Keep/A.swift", "Sources/File3.swift", "Sources/Nested/New.swift"])
        XCTAssertEqual(original.files.count, 3, "An in-flight search keeps its immutable snapshot")
        let updated = try partial.updating(root: root, paths: ["Keep/Unreported.swift"])
        XCTAssertEqual(updated.files, try ProjectFileSearch.index(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources"))
        let deleted = try updated.updating(root: root, paths: ["Sources"])
        XCTAssertEqual(deleted.files.map(\.relativePath), ["Keep/A.swift", "Keep/Unreported.swift"])
    }

    func testIncrementalUpdatesRevalidateAliasesAndRejectDirectoryLinks() throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try write("Sources/View.swift", in: root)
        try write("Secret.swift", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.swift"), withDestinationURL: root.appendingPathComponent("Sources/View.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Broken.swift"), withDestinationURL: root.appendingPathComponent("Sources/Later.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("External"), withDestinationURL: outside)
        var index = try ProjectFileSearch.Index(root: root)
        XCTAssertEqual(Set(index.files.map(\.relativePath)), ["Alias.swift", "Sources/View.swift"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/View.swift"))
        try write("Sources/Later.swift", in: root)
        index = try index.updating(root: root, paths: ["Sources/View.swift", "Sources/Later.swift", "External/Secret.swift", "../Secret.swift"])
        XCTAssertEqual(Set(index.files.map(\.relativePath)), ["Broken.swift", "Sources/Later.swift"])
        try write("Sources/View.swift", in: root)
        index = try index.updating(root: root, paths: ["Sources/View.swift"])
        XCTAssertEqual(index.files, try ProjectFileSearch.index(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Sources"), withDestinationURL: outside)
        index = try index.updating(root: root, paths: ["Sources"])
        XCTAssertTrue(index.files.isEmpty)
    }

    func testChangedPathsCollapseDuplicatesAndIgnoreExcludedOrEscapingPaths() {
        XCTAssertEqual(ProjectFileSearch.changedPaths(["Sources/Nested", "Sources/", "Sources//File.swift", "Tests/New.swift",
            "node_modules/pkg/file.js", "Sources/.git/config", "../escape", "/absolute", "Sources/./File.swift"]), ["Sources", "Tests/New.swift"])
        XCTAssertEqual(ProjectFileSearch.changedPaths(["", "Sources"]), [""])
        XCTAssertTrue(ProjectFileSearch.changedPaths([".build/debug/Bob", ".git/index"]).isEmpty)
    }

    func testCancelledIndexAndSearchStopBeforeTraversing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try ProjectFileSearch.index(root: root)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try ProjectFileSearch.search("view", in: [ProjectFile(relativePath: "View.swift")])) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        try await task.value
    }
}

@MainActor final class CommandPaletteTests: XCTestCase {
    func testSelectionWrapsAndStaysValidWhenResultsChange() {
        var selection = CommandPaletteSelection()
        selection.reconcile(["command", "file:one", "file:two"])
        XCTAssertEqual(selection.selectedID, "command")
        selection.move(by: -1, in: ["command", "file:one", "file:two"])
        XCTAssertEqual(selection.selectedID, "file:two")
        selection.move(by: 1, in: ["command", "file:one", "file:two"])
        XCTAssertEqual(selection.selectedID, "command")
        selection.selectedID = "file:one"
        selection.reconcile(["command", "file:one", "file:three"])
        XCTAssertEqual(selection.selectedID, "file:one", "Late indexing results should preserve keyboard selection")
        selection.reconcile(["command", "file:two"])
        XCTAssertEqual(selection.selectedID, "command")
        selection.selectedID = "file:two"
        selection.reconcile(["command", "file:two"], reset: true)
        XCTAssertEqual(selection.selectedID, "command")
        selection.move(by: 1, in: [])
        XCTAssertNil(selection.selectedID)
    }

    func testFieldEditorRoutesNavigationActivationDismissalAndScopeWithoutEditingText() {
        var query = "view", movements: [Int] = [], submits = 0, escapes = 0, scopes: [Bool] = []
        let field = PaletteSearchField(text: Binding(get: { query }, set: { query = $0 }), placeholder: "Search",
                                       onMove: { movements.append($0) }, onSubmit: { submits += 1 },
                                       onEscape: { escapes += 1 }, onSwitchScope: { scopes.append($0) })
        let coordinator = field.makeCoordinator(), control = NSTextField(), editor = NSTextView()
        for command in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
                        #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
                        #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:))] {
            XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: command))
        }
        XCTAssertEqual(movements, [1, -1]); XCTAssertEqual(submits, 1); XCTAssertEqual(escapes, 1)
        XCTAssertEqual(scopes, [false, true]); XCTAssertEqual(query, "view")
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        editor.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submits, 1, "IME confirmation must not open a result")
    }

    func testSearchResultOpensInEditorPreservesDirtyBuffersAndReusesExistingTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-palette-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("let one = 1".utf8).write(to: root.appendingPathComponent("Sources/One.swift"))
        try Data("let two = 2".utf8).write(to: root.appendingPathComponent("Sources/Two.swift"))
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = try await store.openFileTab("Sources/One.swift")
        store.editorText = "unsaved one"
        store.openPanel(.changes)
        let model = store.commandPalette
        await model.load(projectPath: store.projectPath)
        let stale = Task { await model.search("One") }
        stale.cancel()
        await model.search("two.swift")
        await stale.value
        XCTAssertNil(model.error)
        XCTAssertEqual(model.matchedQuery, "two.swift")
        let result = try XCTUnwrap(model.matches.first)
        store.openFile(result.relativePath, focusEditor: true)
        for _ in 0..<100 where store.editorFocusRequest == nil { try await Task.sleep(for: .milliseconds(10)) }
        let second = try XCTUnwrap(store.selectedTabID)
        XCTAssertNotNil(store.editorFocusRequest)
        XCTAssertEqual(store.selectedPanel, .editor)
        XCTAssertEqual(store.editorPath, root.appendingPathComponent("Sources/Two.swift").path)
        XCTAssertEqual(store.editorText, "let two = 2")
        XCTAssertEqual(store.buffer(for: first)?.text, "unsaved one")
        let reused = try await store.openFileTab(result.relativePath)
        XCTAssertEqual(reused, second)
        store.selectTab(first)
        XCTAssertEqual(store.editorText, "unsaved one")
    }
}
