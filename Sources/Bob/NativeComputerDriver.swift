import AppKit
import ScreenCaptureKit
import ApplicationServices
import BobCore

@MainActor private enum ComputerOperationLease {
    static var owner: UUID?
    static func acquire(_ id: UUID) throws {
        guard owner == nil else { throw BobError.message("Another project is using the computer. Wait for it to finish or stop that agent.") }
        owner = id
    }
    static func release(_ id: UUID) { if owner == id { owner = nil } }
}

@MainActor final class NativeComputerDriver: ComputerDriver {
    private let accessibility = MacAccessibility()
    private let owner = UUID()
    private var generation = 0
    private var inputMonitor: Any?
    var onUserInput: (() -> Void)?
    private static let eventMarker: Int64 = 0x424F42435541
    var permissions: ComputerPermissions { ComputerPermissions(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted()) }
    func applications() -> [ComputerApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = app.bundleIdentifier, !ComputerAppPolicy.isBlocked(id) else { return nil }
            return ComputerApp(bundleID: id, name: app.localizedName ?? id, pid: app.processIdentifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func application(_ bundleID: String) throws -> ComputerApp {
        guard !ComputerAppPolicy.isBlocked(bundleID), bundleID != Bundle.main.bundleIdentifier else { throw BobError.message("This app requires manual interaction.") }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw BobError.message("Bob cannot control itself.") }
            return ComputerApp(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), Bundle(url: url)?.bundleIdentifier == bundleID else { throw BobError.message("No installed app matches this bundle ID.") }
        return ComputerApp(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path), pid: 0)
    }
    func open(_ bundleID: String) async throws -> ComputerApp {
        _ = try application(bundleID)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw BobError.message("The app is not installed.") }
        let token = generation
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try check(token)
        return try application(bundleID)
    }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    private func requirePermissions() throws {
        guard permissions.screenRecording else { throw BobError.message("Grant Bob Screen Recording in the Computer panel, then retry. macOS may require reopening Bob.") }
        guard permissions.accessibility else { throw BobError.message("Grant Bob Accessibility in the Computer panel, then retry.") }
    }
    func capture(_ bundleID: String, windowID: UInt32?) async throws -> ComputerSnapshot {
        try requirePermissions()
        let app = try application(bundleID)
        guard app.pid > 0 else { throw BobError.message("Open the app before capturing it.") }
        try ComputerOperationLease.acquire(owner); defer { ComputerOperationLease.release(owner) }
        let token = generation
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try check(token)
        let windows = content.windows.filter { $0.owningApplication?.processID == app.pid && $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20 }
        func metadata(_ window: SCWindow) -> (frame: CGRect, title: String) {
            if let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowID) as? [[String: Any]])?.first(where: { $0[kCGWindowNumber as String] as? UInt32 == window.windowID }),
               info[kCGWindowOwnerPID as String] as? Int32 == app.pid,
               let raw = info[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) {
                return (frame, info[kCGWindowName as String] as? String ?? window.title ?? "")
            }
            return (window.frame, window.title ?? "")
        }
        let main = await accessibility.mainWindowFrame(appPID: app.pid)
        let window: SCWindow?
        if let windowID { window = windows.first { $0.windowID == windowID } }
        else { window = windows.first(where: { candidate in let frame = metadata(candidate).frame; return main.map { abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2 && abs($0.width - frame.width) < 2 && abs($0.height - frame.height) < 2 } ?? false }) ?? windows.max(by: { let a = metadata($0).frame, b = metadata($1).frame; return a.width * a.height < b.width * b.height }) }
        guard let window else { throw BobError.message("No capturable window for this app. Open a window and try again.") }
        let id = UUID().uuidString
        let details = metadata(window)
        let elements = try await accessibility.capture(appPID: app.pid, frame: details.frame, title: details.title, id: id)
        try check(token)
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1536 / max(details.frame.width, details.frame.height))
        configuration.width = max(1, Int(details.frame.width * scale)); configuration.height = max(1, Int(details.frame.height * scale))
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        try check(token)
        try await accessibility.validate(id: id)
        let redacted = try redact(image, frame: details.frame, elements: elements)
        guard let jpeg = NSBitmapImageRep(cgImage: redacted).representation(using: .jpeg, properties: [.compressionFactor: 0.78]), jpeg.count <= 2 * 1024 * 1024 else { throw BobError.message("The screenshot exceeds the image limit.") }
        return ComputerSnapshot(id: id, app: app, windowID: window.windowID, title: details.title, frame: details.frame, elements: elements, image: ModelImage(data: jpeg, width: redacted.width, height: redacted.height), windows: windows.prefix(30).map { .init(id: $0.windowID, title: String(metadata($0).title.prefix(200))) })
    }
    func redact(_ image: CGImage, frame: CGRect, elements: [ComputerElement]) throws -> CGImage {
        guard elements.contains(where: \.secure) else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw BobError.message("Could not redact protected controls. No screenshot was returned.") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        let sx = Double(image.width) / frame.width, sy = Double(image.height) / frame.height
        for element in elements where element.secure {
            let bounds = element.frame.intersection(frame)
            context.fill(CGRect(x: (bounds.minX - frame.minX) * sx, y: Double(image.height) - (bounds.maxY - frame.minY) * sy, width: bounds.width * sx, height: bounds.height * sy))
        }
        guard let redacted = context.makeImage() else { throw BobError.message("Could not redact protected controls. No screenshot was returned.") }
        return redacted
    }
    private func validateWindow(_ state: ComputerSnapshot) throws {
        let app = try application(state.app.bundleID)
        guard app.pid == state.app.pid else { throw BobError.message("The app restarted. Capture fresh state.") }
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, state.windowID) as? [[String: Any]])?.first(where: { $0[kCGWindowNumber as String] as? UInt32 == state.windowID }),
              info[kCGWindowOwnerPID as String] as? Int32 == state.app.pid,
              let dictionary = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), abs(bounds.minX - state.frame.minX) < 2, abs(bounds.minY - state.frame.minY) < 2,
              abs(bounds.width - state.frame.width) < 2, abs(bounds.height - state.frame.height) < 2 else { throw BobError.message("The app window moved or closed. Capture fresh state.") }
    }
    func perform(_ action: ComputerAction, in state: ComputerSnapshot) async throws {
        try requirePermissions(); try action.validate(in: state); try validateWindow(state)
        try ComputerOperationLease.acquire(owner); defer { ComputerOperationLease.release(owner) }
        let token = generation
        try await accessibility.validate(id: state.id, reference: action.reference, typing: action.kind == .type)
        try check(token)
        if action.kind == .type, let reference = action.reference {
            try await accessibility.replaceText(id: state.id, reference: reference, text: action.text)
            return
        }
        if action.kind == .click, let reference = action.reference, try await accessibility.press(id: state.id, reference: reference) { return }
        // Public AX actions can work in the background. Event fallbacks explicitly raise only the approved app.
        guard let app = NSRunningApplication(processIdentifier: state.app.pid), app.activate(options: []) else { throw BobError.message("Could not activate the approved app.") }
        try await accessibility.raise(id: state.id)
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == state.app.pid { break }
            try await Task.sleep(for: .milliseconds(40)); try check(token)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == state.app.pid else { throw BobError.message("The approved app is not in front. No input was sent.") }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else { return }
            self?.onUserInput?()
        }
        defer { if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }; inputMonitor = nil }
        try check(token); try validateWindow(state)
        let source = CGEventSource(stateID: .privateState)
        func post(_ event: CGEvent?) throws {
            try check(token)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == state.app.pid, let event else { throw BobError.message("App focus changed. No further input was sent.") }
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            if event.type != .keyDown && event.type != .keyUp {
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(state.windowID))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(state.windowID))
            }
            event.postToPid(state.app.pid)
        }
        if action.kind == .key {
            try await accessibility.validateKeyboard(id: state.id)
            let chord = try ComputerKeyChord(action.keys)
            let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true), up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
            down?.flags = chord.modifiers; up?.flags = []
            try post(down); try post(up); return
        }
        let point: CGPoint
        if let reference = action.reference { let frame = try state.element(reference).frame; point = CGPoint(x: frame.midX, y: frame.midY) }
        else if let x = action.x, let y = action.y { point = try state.screenPoint(x: x, y: y) }
        else { point = CGPoint(x: state.frame.midX, y: state.frame.midY) }
        try assertUncovered(point, state: state)
        if action.kind == .scroll {
            let horizontal = ["left", "right"].contains(action.direction), sign = ["down", "right"].contains(action.direction) ? -1 : 1
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: horizontal ? 0 : Int32(action.amount * sign), wheel2: horizontal ? Int32(action.amount * sign) : 0, wheel3: 0)
            event?.location = point; try post(event); return
        }
        let right = action.kind == .rightClick, button: CGMouseButton = right ? .right : .left
        func mouse(_ type: CGEventType, _ point: CGPoint, count: Int64 = 1) -> CGEvent? {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: count)
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(state.windowID))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(state.windowID))
            return event
        }
        if action.kind == .drag {
            let end = try state.screenPoint(x: action.endX!, y: action.endY!)
            try assertUncovered(end, state: state)
            var last = point
            try post(mouse(.leftMouseDown, point))
            defer {
                let up = mouse(.leftMouseUp, last); up?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker); up?.postToPid(state.app.pid)
            }
            for step in 1...16 {
                try await Task.sleep(for: .milliseconds(12)); try check(token)
                let next = CGPoint(x: point.x + (end.x - point.x) * Double(step) / 16, y: point.y + (end.y - point.y) * Double(step) / 16)
                guard !state.elements.contains(where: { $0.secure && $0.frame.contains(next) }) else { throw BobError.message("Dragging across protected controls requires manual interaction.") }
                last = next
                try assertUncovered(last, state: state); try post(mouse(.leftMouseDragged, last))
            }
        } else {
            for count in 1...(action.kind == .doubleClick ? 2 : 1) {
                try post(mouse(right ? .rightMouseDown : .leftMouseDown, point, count: Int64(count)))
                try post(mouse(right ? .rightMouseUp : .leftMouseUp, point, count: Int64(count)))
            }
        }
    }
    private func assertUncovered(_ point: CGPoint, state: ComputerSnapshot) throws {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let dictionary = info[kCGWindowBounds as String] as? [String: Any], let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            guard info[kCGWindowNumber as String] as? UInt32 == state.windowID else { throw BobError.message("The target is covered by another window. Capture fresh app state.") }
            return
        }
        throw BobError.message("The target is off screen. Move the window fully on screen and capture it again.")
    }
    func cancel() { generation += 1; Task { await accessibility.invalidate() } }
}
