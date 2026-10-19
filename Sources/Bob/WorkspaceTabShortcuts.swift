import AppKit
import SwiftUI

/// SwiftUI's built-in Close Window also owns ⌘W. Route it before menu dispatch,
/// only in this project's key window; sheets and other windows keep normal handling.
struct WorkspaceTabShortcuts: NSViewRepresentable {
    let store: AppStore
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak store] event in
            let handled = MainActor.assumeIsolated {
                guard let view, let window = view.window, window.isKeyWindow,
                      (event.window ?? NSApp.keyWindow) === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "w",
                      let store, store.showWorkspacePanel, store.selectedTabID != nil else { return false }
                store.closeSelectedTab()
                return true
            }
            return handled ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
    final class Coordinator {
        var monitor: Any?
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        deinit { stop() }
    }
}
