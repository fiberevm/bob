import AppKit
import XCTest
@testable import Bob

@MainActor final class WorkspaceSplitViewTests: XCTestCase {
    func testNativeSidebarStaysOpenWhenResizedAndAfterClosingItsLastTab() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-sidebar-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("let value = 1\n".utf8).write(to: root.appendingPathComponent("file.swift"))
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let controller = WorkspaceSplitController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        window.setContentSize(NSSize(width: 1180, height: 800))
        controller.view.layoutSubtreeIfNeeded()
        let frame = window.frame
        XCTAssertFalse(controller.panelItem.isCollapsed)
        XCTAssertFalse(controller.panelItem.canCollapse)
        XCTAssertFalse(controller.panelItem.canCollapseFromWindowResize)
        XCTAssertGreaterThanOrEqual(controller.panelItem.viewController.view.frame.width, 420)
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor])
        XCTAssertFalse(store.browser.hasCreatedWebView)

        let tab = try await store.openFileTab("file.swift")
        store.editorText = "unsaved change"
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.panelItem.isCollapsed)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(store.selectedTabID, tab)
        XCTAssertEqual(store.editorText, "unsaved change")

        window.setContentSize(NSSize(width: 900, height: 800))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.panelItem.isCollapsed)
        XCTAssertGreaterThanOrEqual(controller.panelItem.viewController.view.frame.width, 420)
        XCTAssertEqual(store.selectedTabID, tab)
        XCTAssertTrue(store.editorDirty)

        XCTAssertThrowsError(try store.closeTab(tab))
        store.editorText = store.editorOriginal
        try store.closeTab(tab)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(store.openTabs.map(\.kind), [.editor])
        XCTAssertNil(store.editorPath)
        XCTAssertFalse(store.canCloseSelectedTab)
        XCTAssertTrue(store.showWorkspacePanel)
        XCTAssertFalse(controller.panelItem.isCollapsed)
        XCTAssertGreaterThanOrEqual(controller.panelItem.viewController.view.frame.width, 420)
    }
}
