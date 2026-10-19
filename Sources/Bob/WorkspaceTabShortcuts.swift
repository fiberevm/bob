import AppKit
import SwiftUI

/// Route workspace shortcuts before menu dispatch (and terminal text input),
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
                      window.attachedSheet == nil,
                      let store, store.showWorkspacePanel else { return false }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                // Use the physical grave key: Option changes its produced character to a dead key.
                if modifiers == .option && event.keyCode == 50 {
                    if !event.isARepeat { store.toggleEditorTerminal() }
                    return true
                }
                if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w",
                   store.selectedTabID != nil {
                    store.closeSelectedTab()
                    return true
                }
                return false
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
