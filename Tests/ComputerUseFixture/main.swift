import AppKit

final class Fixture: NSObject, NSApplicationDelegate {
    let input = NSTextField(string: "Original")
    let result = NSTextField(labelWithString: "Ready")
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 440, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bob Computer Fixture"; window.isReleasedWhenClosed = false
        input.frame = NSRect(x: 24, y: 200, width: 380, height: 28); input.setAccessibilityLabel("Fixture input")
        let password = NSSecureTextField(string: "never-return-this")
        password.frame = NSRect(x: 24, y: 150, width: 380, height: 28); password.setAccessibilityLabel("Password")
        let button = NSButton(title: "Apply", target: self, action: #selector(apply))
        button.frame = NSRect(x: 24, y: 90, width: 100, height: 32); button.keyEquivalent = "\r"
        result.frame = NSRect(x: 24, y: 40, width: 380, height: 28)
        for view in [input, password, button, result] { window.contentView?.addSubview(view) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? "\(window.title) \(window.frame)".write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
    }
    @objc func apply() { result.stringValue = "Applied: " + input.stringValue }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let fixture = Fixture()
app.delegate = fixture
app.run()
