import AppKit
import SwiftUI
import Darwin
import BobCore

@MainActor final class TerminalSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var running = false
    @Published private(set) var exitStatus: Int32?
    private(set) var directory = ""
    private var process: Process?
    private var master: Int32 = -1
    private var generation = UUID()
    private var escape = ""
    private var inEscape = false
    private var utf8 = Data()
    func start(directory: String) throws {
        guard !directory.isEmpty else { return }
        if running && self.directory == directory { return }
        var env = ExecutableLocator.environment
        env["TERM"] = "dumb"; env["PS1"] = "%1~ ❯ "; env["RPS1"] = ""
        try start(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-i"], directory: directory, environment: env)
    }
    func start(executable: URL, arguments: [String], directory: String, environment: [String: String]) throws {
        stop(); self.directory = directory; output = ""; utf8 = Data(); escape = ""; inEscape = false
        exitStatus = nil
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { throw BobError.message("Could not create a terminal.") }
        let process = Process(), slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardInput = slave; process.standardOutput = slave; process.standardError = slave
        do { try process.run() } catch { close(masterFD); try? slave.close(); throw error }
        try? slave.close()
        self.process = process; master = masterFD; running = true
        let id = UUID(); generation = id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(masterFD, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let data = Data(buffer.prefix(count))
                DispatchQueue.main.async { guard self?.generation == id else { return }; self?.append(data) }
            }
            close(masterFD)
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard self?.generation == id else { return }
                self?.exitStatus = process.terminationStatus; self?.running = false; self?.master = -1
            }
        }
    }
    func send(_ text: String) {
        guard master >= 0 else { return }
        if text == "\u{03}" { process?.interrupt(); return }
        let data = Data(text.utf8)
        data.withUnsafeBytes { bytes in _ = Darwin.write(master, bytes.baseAddress, bytes.count) }
    }
    func clear() { output = "" }
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        self.process = nil; running = false
    }
    private func append(_ data: Data) {
        utf8.append(data)
        // Wait for complete UTF-8 scalars at the end of a PTY read.
        var count = utf8.count
        while count > 0 && String(data: utf8.prefix(count), encoding: .utf8) == nil && utf8.count - count < 4 { count -= 1 }
        guard count > 0 else { return }
        let text = String(decoding: utf8.prefix(count), as: UTF8.self); utf8.removeFirst(count)
        var output = self.output
        for scalar in text.unicodeScalars {
            if inEscape {
                escape.unicodeScalars.append(scalar)
                if escape.hasPrefix("]") {
                    if scalar.value == 7 || escape.hasSuffix("\u{1b}\\") { inEscape = false; escape = "" }
                } else if escape.first == "[" {
                    if escape.count > 1 && (0x40...0x7e).contains(scalar.value) { inEscape = false; escape = "" }
                } else { inEscape = false; escape = "" }
                if escape.count > 2048 { inEscape = false; escape = "" }
                continue
            }
            switch scalar.value {
            case 27: inEscape = true
            case 8, 127: if !output.isEmpty && output.last != "\n" { output.removeLast() }
            case 13: break
            case 10: output.append("\n")
            case 9: output.append("    ")
            case 0..<32: break
            default: output.unicodeScalars.append(scalar)
            }
        }
        if output.count > 160_000 { output = String(output.suffix(120_000)) }
        self.output = output
    }
}

struct TerminalTextView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var focusOnOpen = false
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = TerminalInputView()
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.applyTheme()
        text.textContainerInset = NSSize(width: 18, height: 12)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.onInput = { [weak session] in session?.send($0) }
        scroll.documentView = text
        if focusOnOpen {
            DispatchQueue.main.async { [weak text] in
                guard let text, let window = text.window, window.isKeyWindow else { return }
                window.makeFirstResponder(text)
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TerminalInputView, text.string != session.output else { return }
        let atBottom = scroll.contentView.bounds.maxY >= text.bounds.maxY - 40
        text.string = session.output
        if atBottom { text.scrollToEndOfDocument(nil) }
    }
}

private final class TerminalInputView: AdaptiveTextView {
    var onInput: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36: onInput?("\n")
        case 51: onInput?("\u{7f}")
        case 126: onInput?("\u{1b}[A")
        case 125: onInput?("\u{1b}[B")
        case 124: onInput?("\u{1b}[C")
        case 123: onInput?("\u{1b}[D")
        default: if let chars = event.characters { onInput?(chars) }
        }
    }
    override func paste(_ sender: Any?) { if let text = NSPasteboard.general.string(forType: .string) { onInput?(text) } }
}
